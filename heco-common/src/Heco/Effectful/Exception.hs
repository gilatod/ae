module Heco.Effectful.Exception where

import Effectful (Eff)
import Effectful.Exception (throwIO, Exception(displayException))
import Effectful.Error.Dynamic (CallStack, HasCallStack)

import Data.List (intersperse)
import GHC.Exception (prettyCallStackLines)

data UnhandledHecoException =
    forall e. Exception e => UnhandledHecoException e CallStack

instance Show UnhandledHecoException where
    show (UnhandledHecoException e callStack) = concat $
        [ "Unhandled exception: ", displayException e, "\n  " ]
            ++ intersperse "\n  " (prettyCallStackLines callStack)

instance Exception UnhandledHecoException

runThrowEither :: (HasCallStack, Exception e) => Eff es (Either (CallStack, e) a) -> Eff es a
runThrowEither m =
    m >>= either throw pure
    where
        throw (callStack, e) =
            throwIO $ UnhandledHecoException e callStack