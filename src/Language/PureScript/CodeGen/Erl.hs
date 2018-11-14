{-# LANGUAGE GADTs #-}

-- |
-- This module generates code in the simplified Erlang intermediate representation from Purescript code
--
module Language.PureScript.CodeGen.Erl
  ( module AST
  , moduleToErl
  ) where

import Prelude.Compat

import Language.PureScript.CodeGen.Erl.AST as AST

import qualified Data.Text as T
import Data.Traversable
import Data.Foldable
import Data.Monoid
import Control.Monad (unless, replicateM)

import qualified Data.Set as Set
import Data.Set (Set)

import qualified Data.Map as M
import Data.Maybe (fromMaybe, mapMaybe, catMaybes)
import Control.Monad.Error.Class (MonadError(..))
import Control.Applicative ((<|>))
import Control.Arrow (first, second)
import Control.Monad.Reader (MonadReader(..))
import Control.Monad.Writer (MonadWriter(..))

import Control.Monad.Supply.Class

import Language.PureScript.CoreFn hiding (moduleExports)
import Language.PureScript.Errors (MultipleErrors, rethrow, addHint, ErrorMessageHint(..), SimpleErrorMessage(..), errorMessage, rethrowWithPosition)
import Language.PureScript.Options
import Language.PureScript.Names
import Language.PureScript.Types
import Language.PureScript.Environment as E
import qualified Language.PureScript.Constants as C
import Language.PureScript.Traversals (sndM)
import Language.PureScript.AST (SourceSpan, nullSourceSpan)

import Language.PureScript.CodeGen.Erl.Common
import Language.PureScript.CodeGen.Erl.Optimizer

freshNameErl :: (MonadSupply m) => m T.Text
freshNameErl = fmap (("_@" <>) . T.pack . show) fresh

identToTypeclassCtor :: Ident -> Atom
identToTypeclassCtor a = Atom Nothing (runIdent a)

qualifiedToTypeclassCtor :: Qualified Ident -> Atom
qualifiedToTypeclassCtor (Qualified (Just mn) ident) = Atom (Just $ atomModuleName mn PureScriptModule) (runIdent ident)
qualifiedToTypeclassCtor (Qualified  Nothing ident) = Atom Nothing (runIdent ident)

isTopLevelBinding :: Qualified t -> Bool
isTopLevelBinding (Qualified (Just _) _) = True
isTopLevelBinding (Qualified Nothing _) = False

tyArity :: Type -> Int
tyArity (TypeApp (TypeApp fn _) ty) | fn == E.tyFunction = 1 + tyArity ty
tyArity (ForAll _ ty _) = tyArity ty
tyArity (ConstrainedType _ ty) = 1 + tyArity ty 
tyArity _ = 0

uncurriedFnArity :: ModuleName -> T.Text -> Type -> Maybe Int
uncurriedFnArity moduleName fnName = go (-1)
  where
    go :: Int -> Type -> Maybe Int
    go n (TypeConstructor (Qualified (Just mn) (ProperName fnN)))
      | n >= 1, n <= 10, fnN == (fnName <> T.pack (show n)), mn == moduleName
      = Just n
    go n (TypeApp t1 _) = go (n+1) t1
    go n (ForAll _ ty _) = go n ty
    go _ _ = Nothing

effectUncurried :: ModuleName
effectUncurried = ModuleName [ ProperName "Effect", ProperName "Uncurried" ]

dataFunctionUncurried :: ModuleName
dataFunctionUncurried = ModuleName [ ProperName "Data", ProperName "Function", ProperName "Uncurried" ]

-- |
-- Generate code in the simplified Erlang intermediate representation for all declarations in a
-- module.
--
moduleToErl :: forall m .
    (Monad m, MonadReader Options m, MonadSupply m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
  => E.Environment
  -> Module Ann
  -> [(T.Text, Int)]
  -> [(Ident, Type)]
  -> m ([T.Text], [Erl])
moduleToErl env (Module _ _ mn _ _ declaredExports foreigns decls) foreignExports foreignTypes =
  rethrow (addHint (ErrorInModule mn)) $ do
    res <- traverse topBindToErl decls
    reexports <- traverse reExportForeign foreigns
    let (exports, erlDecls) = biconcat $ res <> reexports
    optimized <- traverse optimize erlDecls
    traverse_ checkExport foreignTypes
    let usedFfi = Set.fromList (map (runIdent . fst) foreignTypes)
        definedFfi = Set.fromList (map fst foreignExports)
        unusedFfi = definedFfi Set.\\ usedFfi
    unless (Set.null unusedFfi) $
      tell $ errorMessage $ UnusedFFIImplementations mn (Ident <$> Set.toAscList unusedFfi)

    let attributes = findAttributes decls

    return (map (\(a,i) -> runAtom a <> "/" <> T.pack (show i)) exports, attributes ++ optimized)
  where

  declaredExportsSet :: Set Ident
  declaredExportsSet = Set.fromList declaredExports

  findAttributes :: [Bind Ann] -> [Erl]
  findAttributes expr = map (uncurry EAttribute) $ mapMaybe getAttribute $ concatMap onBind expr
    where
      getAttribute (TypeApp (TypeApp (TypeConstructor (Qualified (Just _) (ProperName "Attribute"))) (TypeLevelString a)) (TypeLevelString b))
        = Just (a,b)
      getAttribute _ = Nothing

      getType ident = (\(t, _, _) -> t) <$> M.lookup (Qualified (Just mn) ident) (E.names env)

      onRecBind ((_, ident), _) = getType ident
      onBind (NonRec _ ident _) = catMaybes [ getType ident ]
      onBind (Rec vals) = mapMaybe onRecBind vals

  biconcat :: [([a], [b])] -> ([a], [b])
  biconcat x = (concatMap fst x, concatMap snd x)

  types :: M.Map (Qualified Ident) Type
  types = M.map (\(t, _, _) -> t) $ E.names env

  arities :: M.Map (Qualified Ident) Int
  arities = tyArity <$> types

  reExportForeign :: Ident -> m ([(Atom,Int)], [Erl])
  reExportForeign ident = do
    let arity = exportArity ident
        fullArity = fromMaybe 0 (M.lookup (Qualified (Just mn) ident) arities)
    args <- replicateM fullArity freshNameErl
    let body = EApp (EAtomLiteral $ qualifiedToErl' mn ForeignModule ident) (take arity $ map EVar args)
        body' = curriedApp (drop arity $ map EVar args) body
        fun = curriedLambda body' args
    fident <- fmap (Ident . ("f" <>) . T.pack . show) fresh
    let var = Qualified Nothing fident
        wrap e = EBlock [ EVarBind (identToVar fident) fun, e ]
    generateFunctionOverloads Nothing (ssAnn nullSourceSpan) ident (Atom Nothing $ runIdent ident) (Var (ssAnn nullSourceSpan) var) wrap

  curriedLambda :: Erl -> [T.Text] -> Erl
  curriedLambda = foldr (EFun1 Nothing)

  exportArity :: Ident -> Int
  exportArity ident = fromMaybe 0 $ findExport $ runIdent ident

  checkExport :: (Ident, Type) -> m ()
  checkExport (ident, ty) =
    case (findExport (runIdent ident), tyArity ty) of
      (Just m, n) | m > n ->
        throwError . errorMessage $ InvalidFFIArity mn (runIdent ident) m n
      (Nothing, _) ->
        throwError . errorMessage $ MissingFFIImplementations mn [ident]
      _ -> pure ()

  findExport :: T.Text -> Maybe Int
  findExport n = snd <$> find ((n==) . fst) foreignExports

  topBindToErl :: Bind Ann -> m ([(Atom,Int)], [Erl])
  topBindToErl (NonRec ann ident val) = topNonRecToErl ann ident val
  topBindToErl (Rec vals) = biconcat <$> traverse (uncurry . uncurry $ topNonRecToErl) vals

  uncurriedFnArity' :: ModuleName -> T.Text -> Qualified Ident -> Maybe Int
  uncurriedFnArity' fnMod fn ident =
    case M.lookup ident types of
      Just t -> uncurriedFnArity fnMod fn t
      _ -> Nothing

  effFnArity = uncurriedFnArity' effectUncurried "EffectFn" 
  fnArity = uncurriedFnArity' dataFunctionUncurried "Fn"
      
  topNonRecToErl :: Ann -> Ident -> Expr Ann -> m ([(Atom,Int)], [ Erl ])
  topNonRecToErl (ss, _, _, _) ident val = do
    let eann@(_, _, _, meta') = extractAnn val
        ident' = case meta' of
          Just IsTypeClassConstructor -> identToTypeclassCtor ident
          _ -> Atom Nothing $ runIdent ident
        

    generateFunctionOverloads (Just ss) eann ident ident' val id

  generateFunctionOverloads :: Maybe SourceSpan -> Ann -> Ident -> Atom -> Expr Ann -> (Erl -> Erl)  -> m ([(Atom,Int)], [ Erl ])
  generateFunctionOverloads ss eann ident ident' val outerWrapper = do
    -- Always generate the plain curried form, f x y = ... -~~> f() -> fun (X) -> fun (Y) -> ... end end.
    let qident = Qualified (Just mn) ident
    erl <- valueToErl val
    let curried = ( [ (ident', 0) ], [ EFunctionDef ss ident' [] (outerWrapper erl) ] )
    -- For effective > 0 (either plain curried funs, FnX or EffectFnX) generate an uncurried overload
    -- f x y = ... -~~> f(X,Y) -> ((...)(X))(Y).
    -- Relying on inlining to clean up some junk here
    let mkRunApp modName prefix n = App eann (Var eann (Qualified (Just modName) (Ident $ prefix <> T.pack (show n))))
        (wrap, unwrap) = case effFnArity qident of
          Just n -> (mkRunApp effectUncurried C.runEffectFn n, \e -> EApp e [])
          _ | Just n <- fnArity qident -> (mkRunApp dataFunctionUncurried C.runFn n, id)
          _ -> (id, id)

    uncurried <- case effFnArity qident <|> fnArity qident <|> M.lookup qident arities of
      Just arity | arity > 0 -> do
        vars <- replicateM arity freshNameErl
        -- Apply in CoreFn then translate to take advantage of translation of full/partial application
        erl' <- valueToErl $ foldl (\fn a -> App eann fn (Var eann (Qualified Nothing (Ident a)))) (wrap val) vars
        pure ( [ (ident', arity) ], [ EFunctionDef ss ident' vars (outerWrapper (unwrap erl')) ] )
      _ -> pure ([], [])

    let res = curried <> uncurried
    pure $ if ident `Set.member` declaredExportsSet 
            then res
            else ([], snd res)

  bindToErl :: Bind Ann -> m [Erl]
  bindToErl (NonRec _ ident val) =
    pure . EVarBind (identToVar ident) <$> valueToErl' (Just ident) val

  -- For recursive bindings F(X) = E1, G(X) = E2, ... we have a problem as the variables are not
  -- in scope until each expression is defined. To avoid lifting to the top level first generate
  -- funs which take a tuple of such funs F'({F', G'}) -> (X) -> E1 etc.
  -- with occurences of F, G replaced in E1, E2 with F'({F',G'})
  -- and then bind these F = F'({F',G'})
  -- TODO: Only do this if there are multiple mutually recursive bindings! Else a named fun works.
  bindToErl (Rec vals) = do
    let vars = identToVar . snd . fst <$> vals
        varTup = ETupleLiteral $ EVar . (<> "@f") <$> vars
        replaceFun fvar = everywhereOnErl go
          where
            go (EVar f) | f == fvar = EApp (EVar $ f <> "@f") [varTup]
            go e = e

    funs <- forM vals $ \((_, ident), val) -> do
      erl <- valueToErl' Nothing val
      let erl' = foldr replaceFun erl vars
      let fun = EFunFull Nothing [(EFunBinder [varTup] Nothing, erl')]
      pure $ EVarBind (identToVar ident <> "@f") fun
    let rebinds = map (\var -> EVarBind var (EApp (EVar $ var <> "@f") [varTup])) vars
    pure $ funs ++ rebinds

  qualifiedToErl' mn' moduleType ident = Atom (Just $ atomModuleName mn' moduleType) (runIdent ident)

  -- Top level definitions are everywhere fully qualified, variables are not.
  qualifiedToErl (Qualified (Just mn') ident) | mn == mn' && ident `Set.notMember` declaredExportsSet  =
    Atom Nothing (runIdent ident) -- Local reference to local non-exported function
  qualifiedToErl (Qualified (Just mn') ident) = qualifiedToErl' mn' PureScriptModule ident -- Reference other modules or exported things via module name
  qualifiedToErl _ = error "Invalid qualified identifier"

  qualifiedToVar (Qualified _ ident) = identToVar ident

  valueToErl :: Expr Ann -> m Erl
  valueToErl = valueToErl' Nothing

  valueToErl' :: Maybe Ident -> Expr Ann -> m Erl
  valueToErl' _ (Literal (pos, _, _, _) l) =
    rethrowWithPosition pos $ literalToValueErl l
  valueToErl' _ (Var _ (Qualified (Just (ModuleName [ProperName prim])) (Ident undef))) | prim == C.prim, undef == C.undefined =
    return $ EAtomLiteral $ Atom Nothing C.undefined
  valueToErl' _ (Var _ ident) | isTopLevelBinding ident = pure $
    case M.lookup ident arities of
      Just 1 -> EFunRef (qualifiedToErl ident) 1
      _ | Just arity <- effFnArity ident <|> fnArity ident
        , arity > 0 -> EFunRef (qualifiedToErl ident) arity 
      _ -> EApp (EAtomLiteral $ qualifiedToErl ident) []

  valueToErl' _ (Var _ ident) = return $ EVar $ qualifiedToVar ident

  valueToErl' ident (Abs _ arg val) = do
    ret <- valueToErl val
    return $ EFun1 (fmap identToVar ident) (identToVar arg) ret

  valueToErl' _ (Accessor _ prop val) = do
    eval <- valueToErl val
    return $ EApp (EAtomLiteral $ Atom (Just "maps") "get") [EAtomLiteral $ AtomPS Nothing prop, eval]

  valueToErl' _ (ObjectUpdate _ o ps) = do
    obj <- valueToErl o
    sts <- mapM (sndM valueToErl) ps
    return $ EMapUpdate obj (map (first (AtomPS Nothing)) sts)

  valueToErl' _ e@App{} = do
    let (f, args) = unApp e []
    args' <- mapM valueToErl args
    case f of
      Var (_, _, _, Just IsNewtype) _ -> return (head args')
      Var (_, _, _, Just (IsConstructor _ fields)) (Qualified _ ident) | length args == length fields ->
        return $ constructorLiteral (runIdent ident) args'
      Var (_, _, _, Just IsTypeClassConstructor) name ->
        return $ curriedApp args' $ EApp (EAtomLiteral $ qualifiedToTypeclassCtor name) []

      Var _ qi@(Qualified _ _)
        | arity <- fromMaybe 0 (M.lookup qi arities)
        , length args == arity
        -> return $ EApp (EAtomLiteral (qualifiedToErl qi)) args'

      _ -> curriedApp args' <$> valueToErl f
    where
    unApp :: Expr Ann -> [Expr Ann] -> (Expr Ann, [Expr Ann])
    unApp (App _ val arg) args = unApp val (arg : args)
    unApp other args = (other, args)

  valueToErl' _ (Case _ values binders) = do
    vals <- mapM valueToErl values
    (exprs, binders', newvals) <- bindersToErl vals binders
    let ret = EApp (EFunFull Nothing binders') (vals++newvals)
    pure $ case exprs of
      [] -> ret
      _ -> EBlock (exprs ++ [ret])
  valueToErl' _ (Let _ ds val) = do
    ds' <- concat <$> mapM bindToErl ds
    ret <- valueToErl val
    -- TODO: Rename variables rather than creating temporary scope just for this
    -- TODO: This scope doesn't really work probably if we actually want to shadow parent scope (avoiding siblings is fine)
    return $ iife (ds' ++ [ret])

  valueToErl' _ (Constructor (_, _, _, Just IsNewtype) _ _ _) = error "newtype ctor"
  valueToErl' _ (Constructor _ _ (ProperName ctor) fields) =
    let createFn =
          let body = constructorLiteral ctor ((EVar . identToVar) `map` fields)
          in foldr (\f inner -> EFun1 Nothing (identToVar f) inner) body fields
    in pure createFn

  iife exprs = EApp (EFun0 Nothing (EBlock exprs)) []

  constructorLiteral name args = ETupleLiteral (EAtomLiteral (Atom Nothing (toAtomName name)) : args)

  curriedApp :: [Erl] -> Erl -> Erl
  curriedApp = flip (foldl (\fn a -> EApp fn [a]))

  literalToValueErl :: Literal (Expr Ann) -> m Erl
  literalToValueErl = literalToValueErl' EMapLiteral valueToErl

  literalToValueErl' ::  ([(Atom,Erl)] -> Erl) -> (a -> m Erl) -> Literal a -> m Erl
  literalToValueErl' _ _ (NumericLiteral n) = return $ ENumericLiteral n
  literalToValueErl' _ _ (StringLiteral s) = return $ EStringLiteral s
  literalToValueErl' _ _ (CharLiteral c) = return $ ECharLiteral c
  literalToValueErl' _ _ (BooleanLiteral b) = return $ boolToAtom b
  literalToValueErl' _ f (ArrayLiteral xs) = do
    array <- EArrayLiteral <$> mapM f xs
    pure $ EApp (EAtomLiteral $ Atom (Just "array") "from_list") [array]
  literalToValueErl' mapLiteral f (ObjectLiteral ps) = do
    pairs <- mapM (sndM f) ps
    pure $ mapLiteral $ map (first (AtomPS Nothing)) pairs

  boolToAtom :: Bool -> Erl
  boolToAtom True = EAtomLiteral $ Atom Nothing "true"
  boolToAtom False = EAtomLiteral $ Atom Nothing "false"

  bindersToErl :: [Erl] -> [CaseAlternative Ann] -> m ([Erl], [(EFunBinder, Erl)], [Erl])
  bindersToErl vals cases = do
    res <- mapM caseToErl cases
    let arrayVars = map fst $ concatMap (\(_,_,x) -> x) res
        convBinder (count, binds) (_, binders, arrayMatches) =
          (count + length arrayMatches, binds ++ map go binders)
          where
            go (EFunBinder bs z, e) = (EFunBinder (bs++padBinds count arrayMatches) z, e)
        padBinds n binds = replicate n (EVar "_") ++ (map snd binds) ++ replicate (length arrayVars - n - length binds) (EVar "_")
        binders' = snd $ foldl convBinder (0, []) res

    pure (concatMap (\(x,_,_) -> x) res, binders', arrayVars)
    where
    caseToErl :: CaseAlternative Ann -> m ([Erl], [(EFunBinder, Erl)], [(Erl, Erl)])
    caseToErl (CaseAlternative binders alt) = do
      b' <- mapM (binderToErl' vals) binders
      let (bs, erls) = second concat $ unzip b'
      (es, res) <- case alt of
        Right e -> do
          e' <- valueToErl e
          pure ([], [(EFunBinder bs Nothing, e')])
        Left guards -> first concat . unzip <$> mapM (guard bs) guards
      pure (es ++ map ((\f -> f (EFunBinder bs Nothing)) . fst) erls, res, map (first EVar . snd) erls)
    guard bs (ge, e) = do
      var <- freshNameErl
      ge' <- valueToErl ge
      let binder = EFunBinder bs Nothing
          fun = EFunFull Nothing
                  ((binder, ge') :
                  if irrefutable binder then []
                  else [(EFunBinder (replicate (length bs) (EVar "_")) Nothing, boolToAtom False)])
          cas = EApp fun vals
      e' <- valueToErl e
      pure ([EVarBind var cas], (EFunBinder bs (Just $ Guard $ EVar var), e'))

  binderToErl' :: [Erl] -> Binder Ann -> m (Erl,[(EFunBinder -> Erl,(T.Text, Erl))])
  binderToErl' _ (NullBinder _) = pure (EVar "_", [])
  binderToErl' _ (VarBinder _ ident) = pure (EVar $ identToVar ident, [])
  binderToErl' vals (LiteralBinder _ (ArrayLiteral es)) = do
    x <- freshNameErl
    args' <- mapM (binderToErl' vals) es

    let cas binder = EApp (EFunFull Nothing
                ((binder, EApp (EAtomLiteral $ Atom (Just "array") "to_list") [EVar x]) :
                  if irrefutable binder then []
                  else [(EFunBinder (replicate (length vals) (EVar "_")) Nothing, EAtomLiteral $ Atom Nothing "nil")]))
                vals
    var <- freshNameErl

    let arr = EArrayLiteral (map fst args')
    pure (EVar x, ((EVarBind var . cas, (var, arr)) : concatMap snd args'))
  binderToErl' vals (LiteralBinder _ lit) = (,[]) <$> literalToValueErl' EMapPattern (fmap fst . binderToErl' vals) lit
  binderToErl' vals (ConstructorBinder (_, _, _, Just IsNewtype) _ _ [b]) = binderToErl' vals b
  binderToErl' vals (ConstructorBinder _ _ (Qualified _ (ProperName ctorName)) binders) = do
    args' <- mapM (binderToErl' vals) binders
    pure (constructorLiteral ctorName (map fst args'), concatMap snd args')
  binderToErl' vals (NamedBinder _ ident binder) = do
    (e, xs) <- binderToErl' vals binder
    pure (EVarBind (identToVar ident) e, xs)

  irrefutable (EFunBinder bindEs Nothing) = all isVar bindEs
    where isVar (EVar _) = True
          isVar _ = False
  irrefutable _ = False