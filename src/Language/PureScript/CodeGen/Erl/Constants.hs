module Language.PureScript.CodeGen.Erl.Constants where

import Data.String (IsString)

-- Modules

prim :: forall a. (IsString a) => a
prim = "prim@ps"

prelude :: forall a. (IsString a) => a
prelude = "prelude@ps"

dataArray :: forall a. (IsString a) => a
dataArray = "data_array@ps"

eff :: forall a. (IsString a) => a
eff = "control_monad_eff@ps"

effect :: forall a. (IsString a) => a
effect = "effect@ps"

controlApplicative :: forall a. (IsString a) => a
controlApplicative = "control_applicative@ps"

controlSemigroupoid :: forall a. (IsString a) => a
controlSemigroupoid = "control_semigroupoid@ps"

controlBind :: forall a. (IsString a) => a
controlBind = "control_bind@ps"

dataBounded :: forall a. (IsString a) => a
dataBounded = "data_bounded@ps"

dataSemigroup :: forall a. (IsString a) => a
dataSemigroup = "data_semigroup@ps"

dataHeytingAlgebra :: forall a. (IsString a) => a
dataHeytingAlgebra = "data_heytingAlgebra@ps"

dataEq :: forall a. (IsString a) => a
dataEq = "data_eq@ps"

dataOrd :: forall a. (IsString a) => a
dataOrd = "data_ord@ps"

dataSemiring :: forall a. (IsString a) => a
dataSemiring = "data_semiring@ps"

dataRing :: forall a. (IsString a) => a
dataRing = "data_ring@ps"

dataEuclideanRing :: forall a. (IsString a) => a
dataEuclideanRing = "data_euclideanRing@ps"

dataFunction :: forall a. (IsString a) => a
dataFunction = "data_function@ps"

dataFunctionUncurried :: forall a. (IsString a) => a
dataFunctionUncurried = "data_function_uncurried@ps"

dataIntBits :: forall a. (IsString a) => a
dataIntBits = "data_int_bits@ps"
