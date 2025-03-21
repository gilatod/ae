module Heco.Events.InternalTimeStreamEvent where

import Heco.Data.TimePhase (TimePhase, ImmanantContent)
import Data.Vector (Vector)

data InternalTimeStreamEvent
    = OnTimePhaseEnriched TimePhase (Vector ImmanantContent)
    | OnTimePhaseRetented TimePhase
    | OnTimePhaseLost TimePhase