-- |
-- This module optimizes code in the simplified-Erlang intermediate representation.
--
-- The following optimizations are supported:
--
--  * Inlining of (>>=) and ret for the Eff monad
--
module Language.PureScript.CodeGen.Erl.Optimizer (optimize) where

import Prelude.Compat

import Control.Monad.Reader (MonadReader, ask, asks)
import Control.Monad.Supply.Class (MonadSupply)

import Language.PureScript.CodeGen.Erl.AST
import Language.PureScript.Options
import Language.PureScript.CodeGen.Erl.Optimizer.MagicDo
import Language.PureScript.CodeGen.Erl.Optimizer.Blocks
import Language.PureScript.CodeGen.Erl.Optimizer.Common
import Language.PureScript.CodeGen.Erl.Optimizer.Unused
import Language.PureScript.CodeGen.Erl.Optimizer.Inliner
import Language.PureScript.CodeGen.Erl.Optimizer.Guards

-- |
-- Apply a series of optimizer passes to simplified Javascript code
--
optimize :: (MonadReader Options m, MonadSupply m) => Erl -> m Erl
optimize js = do
  noOpt <- asks optionsNoOptimizations
  if noOpt then return js else optimize' js

optimize' :: (MonadReader Options m, MonadSupply m) => Erl -> m Erl
optimize' erl = do
  opts <- ask
  erl' <- untilFixedPoint (pure . tidyUp . applyAll
    [ inlineCommonValues
    , inlineCommonOperators
    ]) erl
  untilFixedPoint (pure . tidyUp) . magicDo opts $ erl'

  where
  tidyUp :: Erl -> Erl
  tidyUp = applyAll
    [ collapseNestedBlocks
    -- , removeUnusedArg
    , inlineSimpleGuards
    ]

untilFixedPoint :: (Monad m, Eq a) => (a -> m a) -> a -> m a
untilFixedPoint f = go
  where
  go a = do
   a' <- f a
   if a' == a then return a' else go a'
