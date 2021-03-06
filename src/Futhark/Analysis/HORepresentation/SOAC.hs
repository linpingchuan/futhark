{-# LANGUAGE TypeFamilies #-}
-- | High-level representation of SOACs.  When performing
-- SOAC-transformations, operating on normal 'Exp' values is somewhat
-- of a nuisance, as they can represent terms that are not proper
-- SOACs.  In contrast, this module exposes a SOAC representation that
-- does not enable invalid representations (except for type errors).
--
-- Furthermore, while standard normalised Futhark requires that the inputs
-- to a SOAC are variables or constants, the representation in this
-- module also supports various index-space transformations, like
-- @replicate@ or @rearrange@.  This is also very convenient when
-- implementing transformations.
--
-- The names exported by this module conflict with the standard Futhark
-- syntax tree constructors, so you are advised to use a qualified
-- import:
--
-- @
-- import Futhark.Analysis.HORepresentation.SOAC (SOAC)
-- import qualified Futhark.Analysis.HORepresentation.SOAC as SOAC
-- @
module Futhark.Analysis.HORepresentation.SOAC
  (
   -- * SOACs
    SOAC (..)
  , inputs
  , setInputs
  , lambda
  , setLambda
  , typeOf
  , width
  -- ** Converting to and from expressions
  , NotSOAC (..)
  , fromExp
  , toExp
  , toSOAC
  -- * SOAC inputs
  , Input (..)
  , varInput
  , identInput
  , isVarInput
  , isVarishInput
  , addTransform
  , addTransforms
  , addInitialTransforms
  , inputArray
  , inputRank
  , inputType
  , inputRowType
  , transformRows
  , transposeInput
  -- ** Input transformations
  , ArrayTransforms
  , noTransforms
  , singleTransform
  , nullTransforms
  , (|>)
  , (<|)
  , viewf
  , ViewF(..)
  , viewl
  , ViewL(..)
  , ArrayTransform(..)
  , transformFromExp
  , soacToStream
  )
  where

import Data.Foldable as Foldable
import Data.Maybe
import Data.Monoid
import qualified Data.Sequence as Seq
import qualified Data.Semigroup as Sem

import qualified Futhark.Representation.AST as Futhark
import Futhark.Representation.SOACS.SOAC (StreamForm(..), getStreamAccums)
import qualified Futhark.Representation.SOACS.SOAC as Futhark
import Futhark.Representation.AST
  hiding (Var, Iota, Rearrange, Reshape, Replicate,
          typeOf)
import Futhark.Transform.Substitute
import Futhark.Construct hiding (toExp)
import Futhark.Transform.Rename (renameLambda)

-- | A single, simple transformation.  If you want several, don't just
-- create a list, use 'ArrayTransforms' instead.
data ArrayTransform = Rearrange Certificates [Int]
                    -- ^ A permutation of an otherwise valid input.
                    | Reshape Certificates (ShapeChange SubExp)
                    -- ^ A reshaping of an otherwise valid input.
                    | ReshapeOuter Certificates (ShapeChange SubExp)
                    -- ^ A reshaping of the outer dimension.
                    | ReshapeInner Certificates (ShapeChange SubExp)
                    -- ^ A reshaping of everything but the outer dimension.
                    | Replicate Certificates Shape
                    -- ^ Replicate the rows of the array a number of times.
                      deriving (Show, Eq, Ord)

instance Substitute ArrayTransform where
  substituteNames substs (Rearrange cs xs) =
    Rearrange (substituteNames substs cs) xs
  substituteNames substs (Reshape cs ses) =
    Reshape (substituteNames substs cs) (substituteNames substs ses)
  substituteNames substs (ReshapeOuter cs ses) =
    ReshapeOuter (substituteNames substs cs) (substituteNames substs ses)
  substituteNames substs (ReshapeInner cs ses) =
    ReshapeInner (substituteNames substs cs) (substituteNames substs ses)
  substituteNames substs (Replicate cs se) =
    Replicate (substituteNames substs cs) (substituteNames substs se)

-- | A sequence of array transformations, heavily inspired by
-- "Data.Seq".  You can decompose it using 'viewF' and 'viewL', and
-- grow it by using '|>' and '<|'.  These correspond closely to the
-- similar operations for sequences, except that appending will try to
-- normalise and simplify the transformation sequence.
--
-- The data type is opaque in order to enforce normalisation
-- invariants.  Basically, when you grow the sequence, the
-- implementation will try to coalesce neighboring permutations, for
-- example by composing permutations and removing identity
-- transformations.
newtype ArrayTransforms = ArrayTransforms (Seq.Seq ArrayTransform)
  deriving (Eq, Ord, Show)

instance Sem.Semigroup ArrayTransforms where
  ts1 <> ts2 = case viewf ts2 of
                 t :< ts2' -> (ts1 |> t) <> ts2'
                 EmptyF    -> ts1

instance Monoid ArrayTransforms where
  mempty = noTransforms
  mappend = (Sem.<>)

instance Substitute ArrayTransforms where
  substituteNames substs (ArrayTransforms ts) =
    ArrayTransforms $ substituteNames substs <$> ts

-- | The empty transformation list.
noTransforms :: ArrayTransforms
noTransforms = ArrayTransforms Seq.empty

-- | Is it an empty transformation list?
nullTransforms :: ArrayTransforms -> Bool
nullTransforms (ArrayTransforms s) = Seq.null s

-- | A transformation list containing just a single transformation.
singleTransform :: ArrayTransform -> ArrayTransforms
singleTransform = ArrayTransforms . Seq.singleton

-- | Decompose the input-end of the transformation sequence.
viewf :: ArrayTransforms -> ViewF
viewf (ArrayTransforms s) = case Seq.viewl s of
                              t Seq.:< s' -> t :< ArrayTransforms s'
                              Seq.EmptyL  -> EmptyF

-- | A view of the first transformation to be applied.
data ViewF = EmptyF
           | ArrayTransform :< ArrayTransforms

-- | Decompose the output-end of the transformation sequence.
viewl :: ArrayTransforms -> ViewL
viewl (ArrayTransforms s) = case Seq.viewr s of
                              s' Seq.:> t -> ArrayTransforms s' :> t
                              Seq.EmptyR  -> EmptyL

-- | A view of the last transformation to be applied.
data ViewL = EmptyL
           | ArrayTransforms :> ArrayTransform

-- | Add a transform to the end of the transformation list.
(|>) :: ArrayTransforms -> ArrayTransform -> ArrayTransforms
(|>) = flip $ addTransform' extract add $ uncurry (flip (,))
   where extract ts' = case viewl ts' of
                         EmptyL     -> Nothing
                         ts'' :> t' -> Just (t', ts'')
         add t' (ArrayTransforms ts') = ArrayTransforms $ ts' Seq.|> t'

-- | Add a transform at the beginning of the transformation list.
(<|) :: ArrayTransform -> ArrayTransforms -> ArrayTransforms
(<|) = addTransform' extract add id
   where extract ts' = case viewf ts' of
                         EmptyF     -> Nothing
                         t' :< ts'' -> Just (t', ts'')
         add t' (ArrayTransforms ts') = ArrayTransforms $ t' Seq.<| ts'

addTransform' :: (ArrayTransforms -> Maybe (ArrayTransform, ArrayTransforms))
              -> (ArrayTransform -> ArrayTransforms -> ArrayTransforms)
              -> ((ArrayTransform,ArrayTransform) -> (ArrayTransform,ArrayTransform))
              -> ArrayTransform -> ArrayTransforms
              -> ArrayTransforms
addTransform' extract add swap t ts =
  fromMaybe (t `add` ts) $ do
    (t', ts') <- extract ts
    combined <- uncurry combineTransforms $ swap (t', t)
    Just $ if identityTransform combined then ts'
           else addTransform' extract add swap combined ts'

identityTransform :: ArrayTransform -> Bool
identityTransform (Rearrange _ perm) =
  Foldable.and $ zipWith (==) perm [0..]
identityTransform _ = False

combineTransforms :: ArrayTransform -> ArrayTransform -> Maybe ArrayTransform
combineTransforms (Rearrange cs2 perm2) (Rearrange cs1 perm1) =
  Just $ Rearrange (cs1<>cs2) $ perm2 `rearrangeCompose` perm1
combineTransforms _ _ = Nothing

-- | Given an expression, determine whether the expression represents
-- an input transformation of an array variable.  If so, return the
-- variable and the transformation.  Only 'Rearrange' and 'Reshape'
-- are possible to express this way.
transformFromExp :: Certificates -> Exp lore -> Maybe (VName, ArrayTransform)
transformFromExp cs (BasicOp (Futhark.Rearrange perm v)) =
  Just (v, Rearrange cs perm)
transformFromExp cs (BasicOp (Futhark.Reshape shape v)) =
  Just (v, Reshape cs shape)
transformFromExp cs (BasicOp (Futhark.Replicate shape (Futhark.Var v))) =
  Just (v, Replicate cs shape)
transformFromExp _ _ = Nothing

-- | One array input to a SOAC - a SOAC may have multiple inputs, but
-- all are of this form.  Only the array inputs are expressed with
-- this type; other arguments, such as initial accumulator values, are
-- plain expressions.  The transforms are done left-to-right, that is,
-- the first element of the 'ArrayTransform' list is applied first.
data Input = Input ArrayTransforms VName Type
             deriving (Show, Eq, Ord)

instance Substitute Input where
  substituteNames substs (Input ts v t) =
    Input (substituteNames substs ts)
    (substituteNames substs v) (substituteNames substs t)

-- | Create a plain array variable input with no transformations.
varInput :: HasScope t f => VName -> f Input
varInput v = withType <$> lookupType v
  where withType = Input (ArrayTransforms Seq.empty) v

-- | Create a plain array variable input with no transformations, from an 'Ident'.
identInput :: Ident -> Input
identInput v = Input (ArrayTransforms Seq.empty) (identName v) (identType v)

-- | If the given input is a plain variable input, with no transforms,
-- return the variable.
isVarInput :: Input -> Maybe VName
isVarInput (Input ts v _) | nullTransforms ts = Just v
isVarInput _                                  = Nothing

-- | If the given input is a plain variable input, with no non-vacuous transforms,
-- return the variable.
isVarishInput :: Input -> Maybe VName
isVarishInput (Input ts v t)
  | nullTransforms ts = Just v
  | Reshape cs [DimCoercion _] :< ts' <- viewf ts, cs == mempty =
      isVarishInput $ Input ts' v t
isVarishInput _ = Nothing

-- | Add a transformation to the end of the transformation list.
addTransform :: ArrayTransform -> Input -> Input
addTransform tr (Input trs a t) =
  Input (trs |> tr) a t

-- | Add several transformations to the end of the transformation
-- list.
addTransforms :: ArrayTransforms -> Input -> Input
addTransforms ts (Input ots a t) = Input (ots <> ts) a t

-- | Add several transformations to the start of the transformation
-- list.
addInitialTransforms :: ArrayTransforms -> Input -> Input
addInitialTransforms ts (Input ots a t) = Input (ts <> ots) a t

-- | Convert SOAC inputs to the corresponding expressions.
inputsToSubExps :: (MonadBinder m) =>
                   [Input] -> m [VName]
inputsToSubExps = mapM inputToExp'
  where inputToExp' (Input (ArrayTransforms ts) a _) =
          foldlM transform a ts

        transform ia (Replicate cs n) =
          certifying cs $
          letExp "repeat" $ BasicOp $ Futhark.Replicate n (Futhark.Var ia)

        transform ia (Rearrange cs perm) =
          certifying cs $
          letExp "rearrange" $ BasicOp $ Futhark.Rearrange perm ia

        transform ia (Reshape cs shape) =
          certifying cs $
          letExp "reshape" $ BasicOp $ Futhark.Reshape shape ia

        transform ia (ReshapeOuter cs shape) = do
          shape' <- reshapeOuter shape 1 . arrayShape <$> lookupType ia
          certifying cs $
            letExp "reshape_outer" $ BasicOp $ Futhark.Reshape shape' ia

        transform ia (ReshapeInner cs shape) = do
          shape' <- reshapeInner shape 1 . arrayShape <$> lookupType ia
          certifying cs $
            letExp "reshape_inner" $ BasicOp $ Futhark.Reshape shape' ia

-- | Return the array name of the input.
inputArray :: Input -> VName
inputArray (Input _ v _) = v

-- | Return the type of an input.
inputType :: Input -> Type
inputType (Input (ArrayTransforms ts) _ at) =
  Foldable.foldl transformType at ts
  where transformType t (Replicate _ shape) =
          arrayOfShape t shape
        transformType t (Rearrange _ perm) =
          rearrangeType perm t
        transformType t (Reshape _ shape) =
          t `setArrayShape` newShape shape
        transformType t (ReshapeOuter _ shape) =
          let Shape oldshape = arrayShape t
          in t `setArrayShape` Shape (newDims shape ++ drop 1 oldshape)
        transformType t (ReshapeInner _ shape) =
          let Shape oldshape = arrayShape t
          in t `setArrayShape` Shape (take 1 oldshape ++ newDims shape)

-- | Return the row type of an input.  Just a convenient alias.
inputRowType :: Input -> Type
inputRowType = rowType . inputType

-- | Return the array rank (dimensionality) of an input.  Just a
-- convenient alias.
inputRank :: Input -> Int
inputRank = arrayRank . inputType

-- | Apply the transformations to every row of the input.
transformRows :: ArrayTransforms -> Input -> Input
transformRows (ArrayTransforms ts) =
  flip (Foldable.foldl transformRows') ts
  where transformRows' inp (Rearrange cs perm) =
          addTransform (Rearrange cs (0:map (+1) perm)) inp
        transformRows' inp (Reshape cs shape) =
          addTransform (ReshapeInner cs shape) inp
        transformRows' inp (Replicate cs n)
          | inputRank inp == 1 =
            Rearrange mempty [1,0] `addTransform`
            (Replicate cs n `addTransform` inp)
          | otherwise =
            Rearrange mempty (2:0:1:[3..inputRank inp]) `addTransform`
            (Replicate cs n `addTransform`
             (Rearrange mempty (1:0:[2..inputRank inp-1]) `addTransform` inp))
        transformRows' inp nts =
          error $ "transformRows: Cannot transform this yet:\n" ++ show nts ++ "\n" ++ show inp

-- | Add to the input a 'Rearrange' transform that performs an @(k,n)@
-- transposition.  The new transform will be at the end of the current
-- transformation list.
transposeInput :: Int -> Int -> Input -> Input
transposeInput k n inp =
  addTransform (Rearrange mempty $ transposeIndex k n [0..inputRank inp-1]) inp

-- | A definite representation of a SOAC expression.
data SOAC lore = Map SubExp (Lambda lore) [Input]
               | Reduce SubExp Commutativity (Lambda lore) [(SubExp,Input)]
               | Scan SubExp (Lambda lore) [(SubExp,Input)]
               | Redomap SubExp Commutativity (Lambda lore) (Lambda lore) [SubExp] [Input]
               | Scanomap SubExp (Lambda lore) (Lambda lore) [SubExp] [Input]
               | Stream SubExp (StreamForm lore) (Lambda lore) [Input]
               | Scatter SubExp (Lambda lore) [Input] [(SubExp, VName)]
            deriving (Show)

-- | Returns the inputs used in a SOAC.
inputs :: SOAC lore -> [Input]
inputs (Map      _ _       arrs) = arrs
inputs (Reduce   _ _ _     args) = map snd args
inputs (Scan     _ _       args) = map snd args
inputs (Redomap  _ _ _ _ _ arrs) = arrs
inputs (Scanomap _ _ _ _  arrs) = arrs
inputs (Stream   _ _ _     arrs) = arrs
inputs (Scatter  _len _lam ivs _as) = ivs

-- | Set the inputs to a SOAC.
setInputs :: [Input] -> SOAC lore -> SOAC lore
setInputs arrs (Map w lam _) =
  Map (newWidth arrs w) lam arrs
setInputs arrs (Reduce w comm lam args) =
  Reduce (newWidth arrs w) comm lam (zip (map fst args) arrs)
setInputs arrs (Scan w lam args) =
  Scan (newWidth arrs w) lam (zip (map fst args) arrs)
setInputs arrs (Redomap w comm lam1 lam ne _) =
  Redomap (newWidth arrs w) comm lam1 lam ne arrs
setInputs arrs (Scanomap w lam1 lam ne _) =
  Scanomap (newWidth arrs w) lam1 lam ne arrs
setInputs arrs (Stream w form lam _) =
  Stream (newWidth arrs w) form lam arrs
setInputs arrs (Scatter w lam _ivs as) =
  Scatter (newWidth arrs w) lam arrs as

newWidth :: [Input] -> SubExp -> SubExp
newWidth [] w = w
newWidth (inp:_) _ = arraySize 0 $ inputType inp

-- | The lambda used in a given SOAC.
lambda :: SOAC lore -> Lambda lore
lambda (Map     _ lam _       ) = lam
lambda (Reduce  _ _ lam _     ) = lam
lambda (Scan    _ lam _       ) = lam
lambda (Redomap  _ _ _ lam2 _ _) = lam2
lambda (Scanomap _ _ lam2 _ _) = lam2
lambda (Stream  _ _ lam      _) = lam
lambda (Scatter _len lam _ivs _as) = lam

-- | Set the lambda used in the SOAC.
setLambda :: Lambda lore -> SOAC lore -> SOAC lore
setLambda lam (Map w _ arrs) =
  Map w lam arrs
setLambda lam (Reduce w comm _ args) =
  Reduce w comm lam args
setLambda lam (Scan w _ args) =
  Scan w lam args
setLambda lam (Redomap w comm lam1 _ ne arrs) =
  Redomap w comm lam1 lam ne arrs
setLambda lam (Scanomap w lam1 _ ne arrs) =
  Scanomap w lam1 lam ne arrs
setLambda lam (Stream w form _ arrs) =
  Stream w form lam arrs
setLambda lam (Scatter len _lam ivs as) =
  Scatter len lam ivs as

-- | The return type of a SOAC.
typeOf :: SOAC lore -> [Type]
typeOf (Map w lam _) =
  mapType w lam
typeOf (Reduce _ _ lam _) =
  lambdaReturnType lam
typeOf (Scan _ _ input) =
  map (inputType . snd) input
typeOf (Redomap w _ outlam inlam nes _) =
  let accrtps = lambdaReturnType outlam
      arrrtps = drop (length nes) $ mapType w inlam
  in  accrtps ++ arrrtps
typeOf (Scanomap w outlam inlam nes _) =
  let accrtps = mapType w outlam
      arrrtps = drop (length nes) $ mapType w inlam
  in  accrtps ++ arrrtps
typeOf (Stream w form lam _) =
  let nes     = getStreamAccums form
      accrtps = take (length nes) $ lambdaReturnType lam
      arrtps  = [ arrayOf (stripArray 1 t) (Shape [w]) NoUniqueness
                  | t <- drop (length nes) (lambdaReturnType lam) ]
  in  accrtps ++ arrtps
typeOf (Scatter _w lam _ivs as) =
  zipWith arrayOfRow (snd $ splitAt (n `div` 2) lam_ts) aws
  where lam_ts = lambdaReturnType lam
        n = length lam_ts
        aws = map fst as

-- | The "width" of a SOAC is the expected outer size of its array
-- inputs _after_ input-transforms have been carried out.
width :: SOAC lore -> SubExp
width (Map w _ _) = w
width (Reduce w _ _ _) = w
width (Scan w _ _) = w
width (Redomap w _ _ _ _ _) = w
width (Scanomap w _ _ _ _) = w
width (Stream w _ _ _) = w
width (Scatter len _lam _ivs _as) = len

-- | Convert a SOAC to the corresponding expression.
toExp :: (MonadBinder m, Op (Lore m) ~ Futhark.SOAC (Lore m)) =>
         SOAC (Lore m) -> m (Exp (Lore m))
toExp soac = Op <$> toSOAC soac

-- | Convert a SOAC to a Futhark-level SOAC.
toSOAC :: MonadBinder m =>
          SOAC (Lore m) -> m (Futhark.SOAC (Lore m))
toSOAC (Map w l as) =
  Futhark.Map w l <$> inputsToSubExps as
toSOAC (Reduce w comm l args) =
  Futhark.Reduce w comm l <$> (zip es <$> inputsToSubExps as)
  where (es, as) = unzip args
toSOAC (Scan w l args) =
  Futhark.Scan w l <$> (zip es <$> inputsToSubExps as)
  where (es, as) = unzip args
toSOAC (Redomap w comm l1 l2 es as) =
  Futhark.Redomap w comm l1 l2 es <$> inputsToSubExps as
toSOAC (Scanomap w l1 l2 es as) =
  Futhark.Scanomap w l1 l2 es <$> inputsToSubExps as
toSOAC (Stream w form lam inps) = do
  let extrtp = staticShapes $ lambdaReturnType lam
      extlam = ExtLambda (lambdaParams lam) (lambdaBody lam) extrtp
  inpexp <- inputsToSubExps inps
  return $ Futhark.Stream w form extlam inpexp
toSOAC (Scatter len lam ivs as) = do
  ivs' <- inputsToSubExps ivs
  return $ Futhark.Scatter len lam ivs' as

-- | The reason why some expression cannot be converted to a 'SOAC'
-- value.
data NotSOAC = NotSOAC -- ^ The expression is not a (tuple-)SOAC at all.
               deriving (Show)

-- | Either convert an expression to the normalised SOAC
-- representation, or a reason why the expression does not have the
-- valid form.
fromExp :: (Op lore ~ Futhark.SOAC lore, HasScope t f, Monad f) =>
           Exp lore -> f (Either NotSOAC (SOAC lore))

fromExp (Op (Futhark.Map w l as)) =
  Right . Map w l <$> traverse varInput as
fromExp (Op (Futhark.Reduce w comm l args)) = do
  let (es,as) = unzip args
  Right . Reduce w comm l . zip es <$> traverse varInput as
fromExp (Op (Futhark.Scan w l args)) = do
  let (es,as) = unzip args
  Right . Scan w l . zip es <$> traverse varInput as
fromExp (Op (Futhark.Redomap w comm l1 l2 es as)) =
  Right . Redomap w comm l1 l2 es <$> traverse varInput as
fromExp (Op (Futhark.Scanomap w l1 l2 es as)) =
  Right . Scanomap w l1 l2 es <$> traverse varInput as
fromExp (Op (Futhark.Stream w form extlam as)) = do
  let mrtps = map hasStaticShape $ extLambdaReturnType extlam
      rtps  = catMaybes mrtps
  if length mrtps == length rtps
  then Right <$> do let lam = Lambda (extLambdaParams extlam)
                                     (extLambdaBody extlam)
                                     rtps
                    Stream w form lam <$> traverse varInput as
  else pure $ Left NotSOAC
fromExp (Op (Futhark.Scatter len lam ivs as)) = do
  ivs' <- traverse varInput ivs
  return $ Right $ Scatter len lam ivs' as
fromExp _ = pure $ Left NotSOAC

-- | To-Stream translation of SOACs.
--   Returns the Stream SOAC and the
--   extra-accumulator body-result ident if any.
soacToStream :: (MonadFreshNames m, Bindable lore, Op lore ~ Futhark.SOAC lore) =>
                SOAC lore -> m (SOAC lore,[Ident])
soacToStream soac = do
  chunk_param <- newParam "chunk" $ Prim int32
  let chvar= Futhark.Var $ paramName chunk_param
      (lam, inps) = (lambda soac, inputs soac)
      w = width soac
  lam'     <- renameLambda lam
  let arrrtps= mapType w lam
      -- the chunked-outersize of the array result and input types
      loutps = [ arrayOfRow t chvar | t <- map rowType   arrrtps ]
      lintps = [ arrayOfRow t chvar | t <- map inputRowType inps ]

  strm_inpids <- mapM (newParam "inp") lintps
  -- Treat each SOAC case individually:
  case soac of
    -- Map(f,a) => is translated in strem's body to:
    -- let strm_resids = map(f,a_ch) in strm_resids
    Map{}  -> do
      -- array result and input IDs of the stream's lambda
      strm_resids <- mapM (newIdent "res") loutps
      let insoac = Futhark.Map chvar lam' $ map paramName strm_inpids
          insbnd = mkLet' [] strm_resids $ Op insoac
          strmbdy= mkBody (oneStm insbnd) $ map (Futhark.Var . identName) strm_resids
          strmpar= chunk_param:strm_inpids
          strmlam= Lambda strmpar strmbdy loutps
          empty_lam = Lambda [] (mkBody mempty []) []
      -- map(f,a) creates a stream with NO accumulators
      return (Stream w (Parallel Disorder Commutative empty_lam []) strmlam inps, [])
    -- Scan(+,nes,a) => is translated in strem's body to:
    -- 1. let scan0_ids   = scan(+, nes, a_ch)
    -- 2. let strm_resids = map (acc `+`,nes, scan0_ids)
    -- 3. let outerszm1id = sizeof(0,strm_resids) - 1
    -- 4. let lasteel_ids = if outerszm1id < 0
    --                      then nes
    --                      else strm_resids[outerszm1id]
    -- 5. let acc'        = acc + lasteel_ids
    --    {acc', strm_resids}
    Scan _ _ nesinps -> do
      -- the array and accumulator result types
      let (nes, _) = unzip nesinps
          accrtps= lambdaReturnType lam
      -- array result and input IDs of the stream's lambda
      strm_resids <- mapM (newIdent "res") loutps

      scan0_ids <- mapM (newIdent "resarr0") loutps
      lastel_ids <- mapM (newIdent "lstel") accrtps
      lastel_tmp_ids <- mapM (newIdent "lstel_tmp") accrtps
      empty_arr <- newIdent "empty_arr" $ Prim Bool
      inpacc_ids <- mapM (newParam "inpacc")accrtps
      outszm1id  <- newIdent "szm1" $ Prim int32
      -- 1. let scan0_ids   = scan(+,nes,a_ch)
      let insoac = Futhark.Scan chvar lam' $ zip nes (map paramName strm_inpids)
          insbnd = mkLet' [] scan0_ids $ Op insoac
      -- 2. let outerszm1id = chunksize - 1
          outszm1bnd = mkLet' [] [outszm1id] $ BasicOp $
                       BinOp (Sub Int32)
                       (Futhark.Var $ paramName chunk_param)
                       (constant (1::Int32))
      -- 3. let lasteel_ids = ...
          empty_arr_bnd = mkLet' [] [empty_arr] $ BasicOp $ CmpOp (CmpSlt Int32)
                          (Futhark.Var $ identName outszm1id)
                          (constant (0::Int32))
          leltmpbnds= zipWith (\ lid arrid -> mkLet' [] [lid] $ BasicOp $
                                              Index (identName arrid) $
                                              fullSlice (identType arrid)
                                              [DimFix $ Futhark.Var $ identName outszm1id]
                              ) lastel_tmp_ids scan0_ids
          lelbnd = mkLet' [] lastel_ids $
                   If (Futhark.Var $ identName empty_arr)
                   (mkBody mempty nes)
                   (mkBody (stmsFromList leltmpbnds) $
                    map (Futhark.Var . identName) lastel_tmp_ids) $
                   ifCommon $ map identType lastel_tmp_ids
      -- 4. let strm_resids = map (acc `+`,nes, scan0_ids)
      maplam <- mkMapPlusAccLam (map (Futhark.Var . paramName) inpacc_ids) lam
      let mapbnd = mkLet' [] strm_resids $ Op $
                   Futhark.Map chvar maplam $ map identName scan0_ids
      -- 5. let acc'        = acc + lasteel_ids
      addlelbdy <- mkPlusBnds lam $ map Futhark.Var $
                   map paramName inpacc_ids++map identName lastel_ids
      -- Finally, construct the stream
      let (addlelbnd,addlelres) = (bodyStms addlelbdy, bodyResult addlelbdy)
          strmbdy= mkBody (stmsFromList [insbnd,outszm1bnd,empty_arr_bnd,lelbnd,mapbnd]<>addlelbnd) $
                          addlelres ++ map (Futhark.Var . identName) strm_resids
          strmpar= chunk_param:inpacc_ids++strm_inpids
          strmlam= Lambda strmpar strmbdy (accrtps++loutps)
      return (Stream w (Sequential nes) strmlam inps,
              map paramIdent inpacc_ids)
    -- Reduce(+,nes,a) => is translated in strem's body to:
    -- 1. let acc0_ids = reduce(+,nes,a_ch) in
    -- 2. let acc'     = acc + acc0_ids    in
    --    {acc'}
    Reduce _ comm _ nesinps -> do
      -- the array and accumulator result types
      let (nes,_) = unzip nesinps
          accrtps= lambdaReturnType lam
      -- array result and input IDs of the stream's lambda
      inpacc_ids <- mapM (newParam "inpacc")  accrtps
      acc0_ids   <- mapM (newIdent "acc0"  )  accrtps
      -- 1. let acc0_ids = reduce(+,nes,a_ch) in
      let insoac = Futhark.Reduce chvar comm lam' $ zip nes (map paramName strm_inpids)
          insbnd = mkLet' [] acc0_ids $ Op insoac
      -- 2. let acc'     = acc + acc0_ids    in
      addaccbdy <- mkPlusBnds lam $ map Futhark.Var $
                   map paramName inpacc_ids++map identName acc0_ids
      -- Construct the stream
      let (addaccbnd,addaccres) = (bodyStms addaccbdy, bodyResult addaccbdy)
          strmbdy= mkBody (oneStm insbnd <> addaccbnd) addaccres
          strmpar= chunk_param:inpacc_ids++strm_inpids
          strmlam= Lambda strmpar strmbdy accrtps
      lam0 <- renameLambda lam
      return (Stream w (Parallel InOrder comm lam0 nes) strmlam inps, [])
    -- Redomap(+,lam,nes,a) => is translated in strem's body to:
    -- 1. let (acc0_ids,strm_resids) = redomap(+,lam,nes,a_ch) in
    -- 2. let acc'                   = acc + acc0_ids          in
    --    {acc', strm_resids}
    Redomap _ comm lamin _ nes _ -> do
      -- the array and accumulator result types
      let accrtps= take (length nes) $ lambdaReturnType lam
          -- the chunked-outersize of the array result and input types
          loutps' = drop (length nes) loutps
          -- the lambda with proper index
          foldlam = lam'
      -- array result and input IDs of the stream's lambda
      strm_resids <- mapM (newIdent "res") loutps'
      inpacc_ids <- mapM (newParam "inpacc")  accrtps
      acc0_ids   <- mapM (newIdent "acc0"  )  accrtps
      -- 1. let (acc0_ids,strm_resids) = redomap(+,lam,nes,a_ch) in
      let insoac = Futhark.Redomap chvar comm lamin foldlam nes (map paramName strm_inpids)
          insbnd = mkLet' [] (acc0_ids++strm_resids) $ Op insoac
      -- 2. let acc'     = acc + acc0_ids    in
      addaccbdy <- mkPlusBnds lamin $ map Futhark.Var $
                   map paramName inpacc_ids++map identName acc0_ids
      -- Construct the stream
      let (addaccbnd,addaccres) = (bodyStms addaccbdy, bodyResult addaccbdy)
          strmbdy= mkBody (oneStm insbnd <> addaccbnd) $
                          addaccres ++ map (Futhark.Var . identName) strm_resids
          strmpar= chunk_param:inpacc_ids++strm_inpids
          strmlam= Lambda strmpar strmbdy (accrtps++loutps')
      lam0 <- renameLambda lamin
      return (Stream w (Parallel InOrder comm lam0 nes) strmlam inps, [])
    -- FIXME? Scanomaps do not become seqstreams.
    Scanomap{} -> return (soac,[])
    -- If the soac is a stream then nothing to do, i.e., return it!
    Stream{} -> return (soac,[])
    -- If the soac is a write, don't try to do anything.
    Scatter{} -> return (soac, [])
    -- HELPER FUNCTIONS
    where mkMapPlusAccLam :: (MonadFreshNames m, Bindable lore)
                          => [SubExp] -> Lambda lore -> m (Lambda lore)
          mkMapPlusAccLam accs plus = do
            let lampars = lambdaParams plus
                (accpars, rempars) = (  take (length accs) lampars,
                                        drop (length accs) lampars  )
                parbnds = zipWith (\ par se -> mkLet' [] [paramIdent par]
                                                         (BasicOp $ SubExp se)
                                  ) accpars accs
                plus_bdy = lambdaBody plus
                newlambdy = Body (bodyAttr plus_bdy)
                                 (stmsFromList parbnds <> bodyStms plus_bdy)
                                 (bodyResult plus_bdy)
            renameLambda $ Lambda rempars newlambdy $ lambdaReturnType plus

          mkPlusBnds :: (MonadFreshNames m, Bindable lore)
                     => Lambda lore -> [SubExp] -> m (Body lore)
          mkPlusBnds plus accels = do
            plus' <- renameLambda plus
            let parbnds = zipWith (\ par se -> mkLet' [] [paramIdent par]
                                                         (BasicOp $ SubExp se)
                                  ) (lambdaParams plus') accels
                body = lambdaBody plus'
            return $ body { bodyStms = stmsFromList parbnds <> bodyStms body }
