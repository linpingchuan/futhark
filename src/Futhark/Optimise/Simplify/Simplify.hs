{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}
module Futhark.Optimise.Simplify.Simplify
  ( Engine.SimpleOps (..)
  , Engine.SimpleM
  , Engine.SimplifyOp
  , Engine.bindableSimpleOps
  , simplifyProg
  , simplifyFun
  , simplifyLambda
  , simplifyStms
  )
  where

import Data.Monoid

import Futhark.Representation.AST
import Futhark.MonadFreshNames
import qualified Futhark.Optimise.Simplify.Engine as Engine
import qualified Futhark.Analysis.SymbolTable as ST
import Futhark.Optimise.Simplify.Rule
import Futhark.Optimise.Simplify.Lore
import Futhark.Tools (intraproceduralTransformation)

-- | Simplify the given program.  Even if the output differs from the
-- output, meaningful simplification may not have taken place - the
-- order of bindings may simply have been rearranged.
simplifyProg :: (MonadFreshNames m, Engine.SimplifiableLore lore) =>
                Engine.SimpleOps lore
             -> RuleBook (Engine.Wise lore)
             -> Engine.HoistBlockers lore
             -> Prog lore
             -> m (Prog (Engine.Wise lore))
simplifyProg simpl rules blockers =
  intraproceduralTransformation $ simplifyFun simpl rules blockers

-- | Simplify the given function.  Even if the output differs from the
-- output, meaningful simplification may not have taken place - the
-- order of bindings may simply have been rearranged.  Runs in a loop
-- until convergence.
simplifyFun :: (MonadFreshNames m, Engine.SimplifiableLore lore) =>
                Engine.SimpleOps lore
             -> RuleBook (Engine.Wise lore)
             -> Engine.HoistBlockers lore
             -> FunDef lore
             -> m (FunDef (Engine.Wise lore))
simplifyFun simpl rules blockers =
  loopUntilConvergence env simpl Engine.simplifyFun removeFunDefWisdom
  where env = Engine.emptyEnv rules blockers

-- | Simplify just a single 'Lambda'.
simplifyLambda :: (MonadFreshNames m, HasScope lore m, Engine.SimplifiableLore lore) =>
                  Engine.SimpleOps lore
               -> RuleBook (Engine.Wise lore)
               -> Engine.HoistBlockers lore
               -> Lambda lore -> [Maybe VName]
               -> m (Lambda (Engine.Wise lore))
simplifyLambda simpl rules blockers orig_lam args = do
  types <- askScope
  let f lam = Engine.localVtable
              (<> ST.fromScope (addScopeWisdom types)) $
              Engine.simplifyLambdaNoHoisting lam args
  loopUntilConvergence env simpl f removeLambdaWisdom orig_lam
  where env = Engine.emptyEnv rules blockers

-- | Simplify a list of 'Stm's.
simplifyStms :: (MonadFreshNames m, HasScope lore m, Engine.SimplifiableLore lore) =>
                Engine.SimpleOps lore
             -> RuleBook (Engine.Wise lore)
             -> Engine.HoistBlockers lore
             -> Stms lore
             -> m (Stms (Engine.Wise lore))
simplifyStms simpl rules blockers orig_bnds = do
  types <- askScope
  let f bnds = Engine.localVtable
               (<> ST.fromScope (addScopeWisdom types)) $
               fmap snd $ Engine.simplifyStms bnds $ return ((), mempty)
  loopUntilConvergence env simpl f (fmap removeStmWisdom) orig_bnds
  where env = Engine.emptyEnv rules blockers

loopUntilConvergence :: (MonadFreshNames m, Engine.SimplifiableLore lore) =>
                        Engine.Env lore
                     -> Engine.SimpleOps lore
                     -> (a -> Engine.SimpleM lore b)
                     -> (b -> a)
                     -> a
                     -> m b
loopUntilConvergence env simpl f g x = do
  (x', changed) <- modifyNameSource $ Engine.runSimpleM (f x) simpl env
  if changed then loopUntilConvergence env simpl f g (g x') else return x'
