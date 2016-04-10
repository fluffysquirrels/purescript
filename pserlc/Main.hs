{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module Main where


import Prelude ()
import Prelude.Compat hiding (lex)

import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Writer.Strict

import Data.List (isSuffixOf, partition)
import Data.Version (showVersion)
import qualified Data.Map as M
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.UTF8 as BU8

import Options.Applicative as Opts

import System.Exit (exitSuccess, exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO.UTF8
import System.FilePath.Glob (glob)

import qualified Language.PureScript as P
import qualified Paths_purescript as Paths


import qualified Text.Parsec as PS

import Language.PureScript.Make hiding (buildMakeActions)

import Language.PureScript.Parser.Common
import Language.PureScript.Parser.Lexer
import Make(buildMakeActions)


import Data.Function (on)
import Data.List (sortBy, groupBy)

import JSON


data PSCMakeOptions = PSCMakeOptions
  { pscmInput        :: [FilePath]
  , pscmForeignInput :: [FilePath]
  , pscmOutputDir    :: FilePath
  , pscmOpts         :: P.Options
  , pscmUsePrefix    :: Bool
  , pscmJSONErrors   :: Bool
  }

data InputOptions = InputOptions
  { ioInputFiles  :: [FilePath]
  }

-- | Arguments: verbose, use JSON, warnings, errors
printWarningsAndErrors :: Bool -> Bool -> P.MultipleErrors -> Either P.MultipleErrors a -> IO ()
printWarningsAndErrors verbose False warnings errors = do
  when (P.nonEmpty warnings) $
    hPutStrLn stderr (P.prettyPrintMultipleWarnings verbose warnings)
  case errors of
    Left errs -> do
      hPutStrLn stderr (P.prettyPrintMultipleErrors verbose errs)
      exitFailure
    Right _ -> return ()
printWarningsAndErrors verbose True warnings errors = do
  hPutStrLn stderr . BU8.toString . B.toStrict . A.encode $
    JSONResult (toJSONErrors verbose P.Warning warnings)
               (either (toJSONErrors verbose P.Error) (const []) errors)
  either (const exitFailure) (const (return ())) errors

compile :: PSCMakeOptions -> IO ()
compile PSCMakeOptions{..} = do
  input <- globWarningOnMisses (unless pscmJSONErrors . warnFileTypeNotFound) pscmInput
  when (null input && not pscmJSONErrors) $ do
    hPutStrLn stderr "pserlc: No input files."
    exitFailure
  let (erlFiles, pursFiles) = partition (isSuffixOf ".erl") input
  moduleFiles <- readInput (InputOptions pursFiles)
  inputForeign <- globWarningOnMisses (unless pscmJSONErrors . warnFileTypeNotFound) pscmForeignInput
  foreignFiles <- forM (inputForeign ++ erlFiles) (\inFile -> (inFile,) <$> readUTF8File inFile)
  (makeErrors, makeWarnings) <- runMake pscmOpts $ do
    (ms, foreigns) <- parseInputs moduleFiles foreignFiles
    let filePathMap = M.fromList $ map (\(fp, P.Module _ _ mn _ _) -> (mn, fp)) ms
        makeActions = buildMakeActions pscmOutputDir filePathMap foreigns pscmUsePrefix
    P.make makeActions (map snd ms)
  printWarningsAndErrors (P.optionsVerboseErrors pscmOpts) pscmJSONErrors makeWarnings makeErrors
  exitSuccess

warnFileTypeNotFound :: String -> IO ()
warnFileTypeNotFound = hPutStrLn stderr . ("pserlc: No files found using pattern: " ++)

globWarningOnMisses :: (String -> IO ()) -> [FilePath] -> IO [FilePath]
globWarningOnMisses warn = concatMapM globWithWarning
  where
  globWithWarning pattern = do
    paths <- glob pattern
    when (null paths) $ warn pattern
    return paths
  concatMapM f = liftM concat . mapM f

readInput :: InputOptions -> IO [(Either P.RebuildPolicy FilePath, String)]
readInput InputOptions{..} = forM ioInputFiles $ \inFile -> (Right inFile, ) <$> readUTF8File inFile

parseInputs :: (MonadError P.MultipleErrors m, MonadWriter P.MultipleErrors m)
            => [(Either P.RebuildPolicy FilePath, String)]
            -> [(FilePath, ForeignErl)]
            -> m ([(Either P.RebuildPolicy FilePath, P.Module)], M.Map P.ModuleName FilePath)
parseInputs modules foreigns =
  (,) <$> P.parseModulesFromFiles (either (const "") id) modules
      <*> parseForeignModulesFromFiles foreigns

type ForeignErl = String

parseForeignModulesFromFiles :: (MonadError P.MultipleErrors m, MonadWriter P.MultipleErrors m)
                             => [(FilePath, ForeignErl)]
                             -> m (M.Map P.ModuleName FilePath)
parseForeignModulesFromFiles files = do
  foreigns <- P.parU files $ \(path, file) ->
    case findModuleName (lines file) of
      Just name -> return (name, path)
      Nothing -> throwError (P.errorMessage $ P.ErrorParsingFFIModule path)
  let grouped = groupBy ((==) `on` fst) $ sortBy (compare `on` fst) foreigns
  forM_ grouped $ \grp ->
    when (length grp > 1) $ do
      let mn = fst (head grp)
          paths = map snd grp
      tell $ P.errorMessage $ P.MultipleFFIModules mn paths
  return $ M.fromList foreigns

findModuleName :: [String] -> Maybe P.ModuleName
findModuleName = msum . map parseComment
  where
  parseComment :: String -> Maybe P.ModuleName
  parseComment s = either (const Nothing) Just $
    lex "" s >>= P.runTokenParser "" (P.symbol' "%" *> P.reserved "module" *> moduleName <* PS.eof)

inputFile :: Parser FilePath
inputFile = strArgument $
     metavar "FILE"
  <> help "The input .purs file(s)"

inputForeignFile :: Parser FilePath
inputForeignFile = strOption $
     short 'f'
  <> long "ffi"
  <> help "The input .erl file(s) providing foreign import implementations"

outputDirectory :: Parser FilePath
outputDirectory = strOption $
     short 'o'
  <> long "output"
  <> Opts.value "output"
  <> showDefault
  <> help "The output directory"

noMagicDo :: Parser Bool
noMagicDo = switch $
     long "no-magic-do"
  <> help "Disable the optimization that overloads the do keyword to generate efficient code specifically for the Eff monad"

noOpts :: Parser Bool
noOpts = switch $
     long "no-opts"
  <> help "Skip the optimization phase"

comments :: Parser Bool
comments = switch $
     short 'c'
  <> long "comments"
  <> help "Include comments in the generated code"

verboseErrors :: Parser Bool
verboseErrors = switch $
     short 'v'
  <> long "verbose-errors"
  <> help "Display verbose error messages"

noPrefix :: Parser Bool
noPrefix = switch $
     short 'p'
  <> long "no-prefix"
  <> help "Do not include comment header"

jsonErrors :: Parser Bool
jsonErrors = switch $
     long "json-errors"
  <> help "Print errors to stderr as JSON"


options :: Parser P.Options
options = P.Options <$> pure False
                    <*> noMagicDo
                    <*> pure Nothing
                    <*> noOpts
                    <*> verboseErrors
                    <*> (not <$> comments)
                    <*> pure Nothing
                    <*> pure False

pscMakeOptions :: Parser PSCMakeOptions
pscMakeOptions = PSCMakeOptions <$> many inputFile
                                <*> many inputForeignFile
                                <*> outputDirectory
                                <*> options
                                <*> (not <$> noPrefix)
                                <*> jsonErrors

main :: IO ()
main = execParser opts >>= compile
  where
  opts        = info (version <*> helper <*> pscMakeOptions) infoModList
  infoModList = fullDesc <> headerInfo <> footerInfo
  headerInfo  = header   "pserlc - Compiles PureScript to Erlang"
  footerInfo  = footer $ "pserlc " ++ showVersion Paths.version

  version :: Parser (a -> a)
  version = abortOption (InfoMsg (showVersion Paths.version)) $ long "version" <> help "Show the version number" <> hidden
