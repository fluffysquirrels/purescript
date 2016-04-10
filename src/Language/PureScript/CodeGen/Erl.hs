{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- This module generates code in the simplified Javascript intermediate representation from Purescript code
--
module Language.PureScript.CodeGen.Erl
  ( module AST
  , moduleToErl
  , moduleExports
  ) where

import Prelude ()
import Prelude.Compat

import Language.PureScript.CodeGen.Erl.AST as AST

import Data.Traversable
import Data.List (intercalate, nub)
import Data.Maybe (mapMaybe, maybeToList)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Reader (MonadReader)
import Control.Monad.Supply.Class
import Control.Monad(when)

import Language.PureScript.CoreFn hiding (moduleExports)
import Language.PureScript.Errors
import Language.PureScript.Options
import Language.PureScript.Names
import Language.PureScript.Types
import Language.PureScript.AST (SourceSpan)
import Language.PureScript.Environment as E

import Language.PureScript.Traversals (sndM)

import Language.PureScript.CodeGen.Erl.Common

import Data.Char (toLower, toUpper, isUpper)

import Debug.Trace


freshNameErl :: (MonadSupply m) => m String
freshNameErl = fmap (("_@" ++) . show) fresh

moduleExports :: forall m .
    (Monad m, MonadReader Options m, MonadSupply m, MonadError MultipleErrors m)
  => Module Ann
  -> m String
moduleExports (Module coms mn imps exps foreigns decls)  = do
  -- TODO nub temporary
  let exps' = nub $ map (\a -> runAtom $ Atom Nothing $ toAtomName $ runIdent a) $ filter (not . upperIdent) exps
      exps'' = map (++ "/0") (exps' ++ map runAtom dctorExports)
  -- traceM $ "Exports: " ++ show exps
  -- traceM $ "Exports/2: " ++ show dctorExports
  pure $ "-export([" ++ intercalate ", " exps'' ++ "])."

  where
    -- TODO must export actual dctor fn
    upperIdent (Ident (h:_)) = isUpper h
    upperIdent _ = False
    dctorExports = concatMap topExports decls

    topExports :: Bind Ann -> [Atom]
    topExports (NonRec ann ident val) = maybeToList $ topExports' ann ident val
    topExports (Rec vals) = mapMaybe (uncurry . uncurry $ topExports') vals

    topExports' ::  Ann -> Ident -> Expr Ann -> Maybe Atom
    topExports' _ ident val =
      let (_, _, _, meta') = extractAnn val
      in case (meta', val) of
        (Just IsTypeClassConstructor, _) -> Just $ identToTypeclassCtor ident
        (_, Constructor _ _ (ProperName ctor) _) ->
          Just $ Atom Nothing (identToAtomName ident)
        _ -> Nothing

identToTypeclassCtor a = Atom Nothing (identToAtomName a ++ "@tctor")

qualifiedToTypeclassCtor (Qualified (Just mn) ident) = Atom (Just $ atomModuleName mn) (toAtomName $ runIdent ident ++ "@tctor")
qualifiedToTypeclassCtor (Qualified  Nothing ident) = Atom Nothing (toAtomName $ runIdent ident ++ "@tctor")



isTopLevelBinding (Qualified (Just _) _) = True
isTopLevelBinding (Qualified Nothing _) = False



-- |
-- Generate code in the simplified Erlang intermediate representation for all declarations in a
-- module.
--
moduleToErl :: forall m .
    (Monad m, MonadReader Options m, MonadSupply m, MonadError MultipleErrors m)
  => Module Ann
  -- -> Maybe Erl
  -> m [Erl]
moduleToErl (Module _ mn _ exps foreigns decls)  =
  rethrow (addHint (ErrorInModule mn)) $ do
    -- traceShowM ("Module", mn, foreigns)
    erlDecls <- mapM topBindToErl decls
    let foreignExports = mapMaybe reExportForeign foreigns
    return $ foreignExports ++ concat erlDecls
  where

  reExportForeign (ident, ty) | ident `elem` exps = Just $
    if isFnTy ty then
      -- EFunctionDef (Atom Nothing $ identToAtomName ident) ["X"] $ EApp (EAtomLiteral $ qualifiedToErl' mn True ident) [EVar "X"]
      EFunctionDef (Atom Nothing $ identToAtomName ident) [] $
        EFun Nothing "X" $ EApp (EAtomLiteral $ qualifiedToErl' mn True ident) [EVar "X"]
    else
      EFunctionDef (Atom Nothing $ identToAtomName ident) [] $ EApp (EAtomLiteral $ qualifiedToErl' mn True ident) []
  reExportForeign _ = Nothing

  topBindToErl :: Bind Ann -> m [Erl]
  topBindToErl (NonRec ann ident val) = return <$> topNonRecToErl ann ident val
  topBindToErl (Rec vals) = forM vals (uncurry . uncurry $ topNonRecToErl)

  topNonRecToErl ::  Ann -> Ident -> Expr Ann -> m Erl
  topNonRecToErl (_,_,ty,meta) ident val = do
    erl <- valueToErl val
    let (_, _, _, meta') = extractAnn val
    -- traceM $ "binder: " ++ (runIdent ident) ++ ": " ++ show meta' ++ "\n"
    let ident' = case meta' of
          Just IsTypeClassConstructor -> identToTypeclassCtor ident
          _ -> Atom Nothing $ identToAtomName ident
    pure $ EFunctionDef ident' [] erl

  bindToErl :: Bind Ann -> m [Erl]
  bindToErl (NonRec ann ident val) = return <$> nonRecToErl ann ident val
  bindToErl (Rec vals) = forM vals (uncurry . uncurry $ nonRecToErl)

  nonRecToErl ::  Ann -> Ident -> Expr Ann -> m Erl
  nonRecToErl _ ident val = do
    erl <- valueToErl' (Just ident) val
    pure $ EVarBind (identToVar ident) erl




  qualifiedToErl' mn' isForeign ident =
    Atom (Just $ atomModuleName mn' ++ (if isForeign then "@foreign" else "")) (identToAtomName ident)

  -- Top level definitions are everywhere fully qualified, variables are not.
  qualifiedToErl (Qualified (Just mn') ident) | mn == mn' = Atom Nothing (identToAtomName ident)
  qualifiedToErl (Qualified (Just mn') ident) = qualifiedToErl' mn' False ident

  -- Top level definitions are everywhere fully qualified, variables are not.
  qualifiedProperNameToErl (Qualified (Just mn') pn) | mn == mn' = Atom Nothing (toAtomName $ runProperName pn)
  qualifiedProperNameToErl (Qualified (Just mn') pn) =
    Atom (Just $ atomModuleName mn') (toAtomName $ runProperName pn)

  qualifiedToVar (Qualified _ ident) = identToVar ident

  isFnTy :: Type -> Bool
  isFnTy (TypeApp (TypeApp fn _) _) | fn == E.tyFunction = True
  isFnTy (ForAll _ ty _) = isFnTy ty
  isFnTy _ = False

  valueToErl :: Expr Ann -> m Erl
  valueToErl = valueToErl' Nothing

  valueToErl' :: Maybe Ident -> Expr Ann -> m Erl
  valueToErl' _ (Literal (pos, _, _, _) l) =
    maybe id rethrowWithPosition pos $ literalToValueErl l

  valueToErl' _ (Var v@(_, _, Just ty, Just IsForeign) (Qualified (Just mn') ident)) | not (isFnTy ty) && mn == mn' =
    return $  EApp (EAtomLiteral $ qualifiedToErl' mn' True ident) []
  valueToErl' _ (Var v@(_, _, _, Just IsForeign) (Qualified (Just mn') ident)) | mn == mn' = do
    -- traceShowM (mn, mn', ident)
    return $ EFunRef (qualifiedToErl' mn' True ident) 1
  valueToErl' _ (Var v@(_, _, _, Just IsForeign) (Qualified (Just mn') ident)) =
    return $ EApp (EAtomLiteral $ qualifiedToErl' mn' False ident) []
  valueToErl' _ (Var (_, _, _, Just IsForeign) ident) =
    error $ "Encountered an unqualified reference to a foreign ident " ++ showQualified showIdent ident
  valueToErl' _ (Var _ ident) | isTopLevelBinding ident = return $ EApp (EAtomLiteral $ qualifiedToErl ident) []
  valueToErl' _ (Var _ ident) = return $ EVar $ qualifiedToVar ident

  valueToErl' ident (Abs _ arg val) = do
    ret <- valueToErl val
    return $ EFun (fmap identToVar ident) (identToVar arg) ret

  valueToErl' _ (Accessor _ prop val) = do
    eval <- valueToErl val
    return $ EApp (EAtomLiteral $ Atom (Just "maps") "get") [EAtomLiteral $ Atom Nothing prop, eval]

  valueToErl' _ (ObjectUpdate _ o ps) = do
    obj <- valueToErl o
    sts <- mapM (sndM valueToErl) ps
    return $ EMapUpdate obj (map (\(s,e) -> (Atom Nothing s, e)) sts)

  valueToErl' _ e@App{} = do
    let (f, args) = unApp e []
    args' <- mapM valueToErl args
    case f of
      Var (_, _, _, Just IsNewtype) _ -> return (head args')
      Var (_, _, _, Just (IsConstructor _ fields)) name | length args == length fields ->
        return $ constructorLiteral (qualifiedToErl name) args'
      Var (_, _, _, Just IsTypeClassConstructor) name ->
         return $ flip (foldl (\fn a -> EApp fn [a])) args' $ EApp (EAtomLiteral $ qualifiedToTypeclassCtor name) []

      _ -> flip (foldl (\fn a -> EApp fn [a])) args' <$> valueToErl f
    where
    unApp :: Expr Ann -> [Expr Ann] -> (Expr Ann, [Expr Ann])
    unApp (App _ val arg) args = unApp val (arg : args)
    unApp other args = (other, args)

  valueToErl' _ (Case _ values binders) = do
    vals <- mapM valueToErl values
    (exprs, binders') <- bindersToErl vals binders
    let ret = EApp (EFunFull binders') vals
    pure $ case exprs of
      [] -> ret
      _ -> EBlock (exprs ++ [ret])
  valueToErl' _ (Let _ ds val) = do
    ds' <- concat <$> mapM bindToErl ds
    ret <- valueToErl val
    return $ EBlock (ds' ++ [ret])


  valueToErl' _ (Constructor (_, _, _, Just IsNewtype) _ (ProperName _) _) = error "newtype ctor"
  valueToErl' _ (Constructor (_, _, _, meta) _ (ProperName ctor) fields) =
    -- traceShow meta $
    let createFn =
          let body = constructorLiteral (Atom Nothing $ toAtomName ctor) ((EVar . identToVar) `map` fields)
          in foldr (\f inner -> EFun Nothing (identToVar f) inner) body fields
    in pure createFn

  valueToErl' _ x = error $ "Error: " ++ show x

  constructorLiteral name args = ETupleLiteral (EAtomLiteral name : args)

  literalToValueErl :: Literal (Expr Ann) -> m Erl
  literalToValueErl = literalToValueErl' valueToErl

  literalToValueErl' :: (a -> m Erl) -> Literal a -> m Erl
  literalToValueErl' _ (NumericLiteral n) = return $ ENumericLiteral n
  literalToValueErl' _ (StringLiteral s) = return $ EStringLiteral s
  literalToValueErl' _ (CharLiteral c) = return $ ECharLiteral c
  literalToValueErl' _ (BooleanLiteral b) = return $ boolToAtom b
  literalToValueErl' f (ArrayLiteral xs) = do
    array <- EArrayLiteral <$> mapM f xs
    pure $ EApp (EAtomLiteral $ Atom (Just "array") "from_list") [array]
  literalToValueErl' f (ObjectLiteral ps) = do
    pairs <- mapM (sndM f) ps
    pure $ EMapLiteral $ map (\(a,e) -> (Atom Nothing a, e)) pairs

  boolToAtom :: Bool -> Erl
  boolToAtom True = EAtomLiteral $ Atom Nothing "true"
  boolToAtom False = EAtomLiteral $ Atom Nothing "false"

  bindersToErl :: [Erl] -> [CaseAlternative Ann] -> m ([Erl], [(EFunBinder, Erl)])
  bindersToErl vals cases = do
    res <- mapM caseToErl cases
    pure (concatMap fst res, concatMap snd res)
    where
    caseToErl :: CaseAlternative Ann -> m ([Erl], [(EFunBinder, Erl)])
    caseToErl (CaseAlternative binders (Right e)) = do
      bs <- mapM binderToErl' binders
      e' <- valueToErl e
      pure ([], [(EFunBinder bs Nothing, e')])
    caseToErl (CaseAlternative binders (Left guards)) = do
      bs <- mapM binderToErl' binders
      res <- mapM (guard bs) guards
      pure (concatMap fst res, map snd res)
      where guard bs (Literal _ l, e) = do
              lit <- literalToValueErl l
              let bnd = EFunBinder bs (Just $ Guard lit)
              e' <- valueToErl e
              pure ([], (bnd, e'))
            guard bs (ge, e) = do
              var <- freshNameErl
              ge' <- valueToErl ge
              let fun = EFunFull [(EFunBinder bs Nothing, ge'),
                                  (EFunBinder (replicate (length bs) (EVar "_")) Nothing, boolToAtom False)]
                  cas = EApp fun vals
              e' <- valueToErl e
              pure ([EVarBind var cas], (EFunBinder bs (Just $ Guard $ EVar var), e'))

    err = EAtomLiteral $ Atom Nothing "compiler_error"

  binderToErl' :: Binder a -> m Erl
  binderToErl' (NullBinder _) = pure $ EVar "_"
  binderToErl' (VarBinder _ ident) = pure $ EVar $ identToVar ident
  binderToErl' (LiteralBinder _ lit) = (literalToValueErl' binderToErl') lit
  binderToErl' (ConstructorBinder _ _ (ctorName) binders) = do
    args' <- mapM binderToErl' binders
    let nameAtom = case ctorName of
          Qualified _ pn -> Atom Nothing (toAtomName $ runProperName pn)
    pure $ constructorLiteral nameAtom args'
