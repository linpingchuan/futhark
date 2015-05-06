{-# LANGUAGE TypeFamilies #-}
-- | The simplification engine is only willing to hoist allocations
-- out of loops if the memory block resulting from the allocation is
-- dead at the end of the loop.  If it is not, we may cause data
-- hazards.
--
-- This module rewrites loops with memory block merge parameters such
-- that each memory block is copied at the end of the iteration, thus
-- ensuring that any allocation inside the loop is dead at the end of
-- the loop.  This is only possible for allocations whose size is
-- loop-invariant, of course.
module Futhark.Optimise.DoubleBuffer
       ( optimiseProg )
       where

import           Control.Applicative
import           Control.Monad.State
import qualified Data.HashMap.Lazy as HM
import           Data.Maybe

import           Prelude

import           Futhark.MonadFreshNames
import           Futhark.Representation.ExplicitMemory
import qualified Futhark.Representation.ExplicitMemory.IndexFunction.Unsafe as IxFun

optimiseProg :: Prog -> Prog
optimiseProg prog = evalState (Prog <$> mapM optimiseFunDec (progFunctions prog)) src
  where src = newNameSourceForProg prog

optimiseFunDec :: MonadFreshNames m => FunDec -> m FunDec
optimiseFunDec fundec = do
  body' <- optimiseBody $ funDecBody fundec
  return fundec { funDecBody = body' }

optimiseBody :: MonadFreshNames m => Body -> m Body
optimiseBody body = do
  bnds' <- concat <$> mapM optimiseBinding (bodyBindings body)
  return $ body { bodyBindings = bnds' }

optimiseBinding :: MonadFreshNames m => Binding -> m [Binding]
optimiseBinding (Let pat () (LoopOp (DoLoop res merge form body))) = do
  (bnds, merge', body') <- optimiseLoop merge body
  return $ bnds ++ [Let pat () $ LoopOp $ DoLoop res merge' form body']
optimiseBinding (Let pat () e) = pure <$> Let pat () <$> mapExpM optimise e
  where optimise = identityMapper { mapOnBody = optimiseBody
                                  }

optimiseLoop :: MonadFreshNames m =>
                [(FParam, SubExp)] -> Body
             -> m ([Binding], [(FParam, SubExp)], Body)
optimiseLoop mergeparams body = do
  -- We start out by figuring out which of the merge variables should
  -- be double-buffered.
  buffered <- doubleBufferMergeParams $ map fst mergeparams
  -- Then create the allocations of the buffers.
  let allocs = allocBindings buffered
  -- Modify the loop body to copy buffered result arrays.
  let body' = doubleBufferResult (map fst mergeparams) buffered body
  return (allocs, mergeparams, body')

data DoubleBuffer = BufferAlloc VName SubExp
                  | BufferCopy VName IxFun.IxFun VName
                    -- ^ First name is the memory block to copy to,
                    -- second is the name of the array copy.
                  | NoBuffer

doubleBufferMergeParams :: MonadFreshNames m =>
                           [FParam] -> m [DoubleBuffer]
doubleBufferMergeParams params = evalStateT (mapM buffer params) HM.empty
  where paramnames = map paramName params
        loopInvariantSize (Constant _) = True
        loopInvariantSize (Var v)      = v `notElem` paramnames
        buffer fparam = case paramType fparam of
          Mem size
            | loopInvariantSize size -> do
                -- Let us double buffer this!
                bufname <- lift $ newVName "double_buffer_mem"
                modify $ HM.insert (paramName fparam) bufname
                return $ BufferAlloc bufname size
          Array {}
            | MemSummary mem ixfun <- paramLore fparam -> do
                buffered <- gets $ HM.lookup mem
                case buffered of
                  Just bufname -> do
                    copyname <- lift $ newVName "double_buffer_array"
                    return $ BufferCopy bufname ixfun copyname
                  Nothing ->
                    return NoBuffer
          _ -> return NoBuffer

allocBindings :: [DoubleBuffer] -> [Binding]
allocBindings = mapMaybe allocation
  where allocation (BufferAlloc name size) =
          Just $
          Let (Pattern [] [PatElem (Ident name $ Mem size) BindVar Scalar]) () $
          PrimOp $ Alloc size
        allocation _ =
          Nothing

doubleBufferResult :: [FParam] -> [DoubleBuffer] -> Body -> Body
doubleBufferResult mergeparams buffered (Body () bnds res) =
  let (copybnds,ses) =
        unzip $ zipWith3 buffer mergeparams buffered res
  in Body () (bnds++catMaybes copybnds) ses
  where buffer _ (BufferAlloc bufname _) _ =
          (Nothing, Var bufname)

        buffer fparam (BufferCopy bufname ixfun copyname) (Var v) =
          -- To construct the copy we will need to figure out its type
          -- based on the type of the function parameter.
          let t = resultType $ paramType fparam
              ident = Ident copyname t
              summary = MemSummary bufname ixfun
              copybnd = Let (Pattern [] [PatElem ident BindVar summary]) () $
                        PrimOp $ Copy v
          in (Just copybnd, Var copyname)

        buffer _ _ se =
          (Nothing, se)

        parammap = HM.fromList $ zip (map paramName mergeparams) res

        resultType t = t `setArrayDims` map substitute (arrayDims t)

        substitute (Var v)
          | Just replacement <- HM.lookup v parammap = replacement
        substitute se =
          se