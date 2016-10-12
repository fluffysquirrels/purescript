{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}

module Make where

import Prelude ()
import Prelude.Compat

import Control.Monad hiding (sequence)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Writer.Class (MonadWriter(..))
import Control.Monad.Trans.Class (MonadTrans(..))
import Control.Monad.IO.Class
import Control.Monad.Supply

import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Time.Clock
import Data.String (fromString)
import Data.Foldable (for_)
import Data.Version (showVersion)
import qualified Data.Map as M

import Data.Char (toLower)

import System.Directory
       (doesFileExist, getModificationTime, createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)
import System.IO.Error (tryIOError)
import System.IO.UTF8 (readUTF8File, writeUTF8File)

import Language.PureScript.CodeGen.Erl as J
import Language.PureScript (Make, RebuildPolicy, ProgressMessage, Externs)
import Language.PureScript.Make (MakeActions(..), renderProgressMessage)

import Language.PureScript.Crash
import Language.PureScript.Environment
import Language.PureScript.Errors
import Language.PureScript.Names
import Language.PureScript.Pretty
import Language.PureScript.Parser.Erl

import Paths_purescript as Paths

import Language.PureScript.CoreFn as CF

-- |
-- A set of make actions that read and write modules from the given directory.
--
buildMakeActions :: FilePath -- ^ the output directory
                 -> M.Map ModuleName (Either RebuildPolicy FilePath) -- ^ a map between module names and paths to the file containing the PureScript module
                 -> M.Map ModuleName FilePath -- ^ a map between module name and the file containing the foreign javascript for the module
                 -> Bool -- ^ Generate a prefix comment?
                 -> MakeActions Make
buildMakeActions outputDir filePathMap foreigns usePrefix =
  MakeActions getInputTimestamp getOutputTimestamp readExterns codegen progress
  where

  getInputTimestamp :: ModuleName -> Make (Either RebuildPolicy (Maybe UTCTime))
  getInputTimestamp mn = do
    let path = fromMaybe (internalError "Module has no filename in 'make'") $ M.lookup mn filePathMap
    e1 <- traverseEither getTimestamp path
    fPath <- maybe (return Nothing) getTimestamp $ M.lookup mn foreigns
    return $ fmap (max fPath) e1

  getOutputTimestamp :: ModuleName -> Make (Maybe UTCTime)
  getOutputTimestamp mn = do
    let filePath = runModuleName mn
        erlFile = outputDir </> filePath </> "index.erl"
        externsFile = outputDir </> filePath </> "externs.json"
    min <$> getTimestamp erlFile <*> getTimestamp externsFile

  readExterns :: ModuleName -> Make (FilePath, Externs)
  readExterns mn = do
    let path = outputDir </> runModuleName mn </> "externs.json"
    (path, ) <$> readTextFile path

  codegen :: CF.Module CF.Ann -> Environment -> Externs -> SupplyT Make ()
  codegen m _ exts = do
    let mn = CF.moduleName m
    foreignExports <- lift $ case mn `M.lookup` foreigns of
      Just path
        | not $ requiresForeign m -> do
            tell $ errorMessage $ UnnecessaryFFIModule mn path
            return []
        | otherwise -> getForeigns path
      Nothing -> do
        when (requiresForeign m) $ throwError . errorMessage $ MissingFFIModule mn
        return []

    rawErl <- J.moduleToErl m foreignExports
    let pretty = prettyPrintErl rawErl
    let moduleName = runModuleName mn
        outFile = outputDir </> moduleName </> erlModuleName mn ++ ".erl"
        externsFile = outputDir </> moduleName </> "externs.json"
        foreignFile = outputDir </> moduleName </> erlModuleName mn ++ "@foreign.erl"
        prefix = ["Generated by psc version " ++ showVersion Paths.version | usePrefix]
        module' = "-module(" ++ erlModuleName mn ++ ")."
        directives = [
          "-compile(nowarn_shadow_vars).",
          "-compile(nowarn_unused_vars)."  -- consider using _ vars
          ]
    exports <- J.moduleExports m foreignExports
    let erl = unlines $ map ("% " ++) prefix ++ [ module', exports ] ++ directives ++ [ pretty ]
    lift $ do
      writeTextFile outFile (fromString erl)
      for_ (mn `M.lookup` foreigns) (readTextFile >=> writeTextFile foreignFile)
      writeTextFile externsFile exts

  getForeigns :: String -> Make [(String, Int)]
  getForeigns path = do
    text <- readTextFile path
    pure $ either (const []) id $ parseFile path text

  erlModuleName :: ModuleName -> String
  erlModuleName (ModuleName pns) = intercalate "_" ((toAtomName . runProperName) `map` pns)
    where
    -- TODO consolidate
      toAtomName :: String -> String
      toAtomName (h:t) = toLower h : t
      toAtomName [] = []

  requiresForeign :: CF.Module a -> Bool
  requiresForeign = not . null . CF.moduleForeign

  getTimestamp :: FilePath -> Make (Maybe UTCTime)
  getTimestamp path = makeIO (const (ErrorMessage [] $ CannotGetFileInfo path)) $ do
    exists <- doesFileExist path
    traverse (const $ getModificationTime path) $ guard exists

  readTextFile :: FilePath -> Make String
  readTextFile path = makeIO (const (ErrorMessage [] $ CannotReadFile path)) $ readUTF8File path

  writeTextFile :: FilePath -> String -> Make ()
  writeTextFile path text = makeIO (const (ErrorMessage [] $ CannotWriteFile path)) $ do
    mkdirp path
    writeUTF8File path text
    where
    mkdirp :: FilePath -> IO ()
    mkdirp = createDirectoryIfMissing True . takeDirectory

  progress :: ProgressMessage -> Make ()
  progress = liftIO . putStrLn . renderProgressMessage


-- Traverse (Either e) instance (base 4.7)
traverseEither :: Applicative f => (a -> f b) -> Either e a -> f (Either e b)
traverseEither _ (Left x) = pure (Left x)
traverseEither f (Right y) = Right <$> f y


makeIO :: (IOError -> ErrorMessage) -> IO a -> Make a
makeIO f io = do
  e <- liftIO $ tryIOError io
  either (throwError . singleError . f) return e
