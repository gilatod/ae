module Heco.Data.Message where

import Heco.Data.Unique ()

import Effectful (Eff, (:>), IOE, MonadIO (liftIO))

import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TL
import Data.Text.Lazy.Builder qualified as TLB
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as Map
import Data.Unique (Unique, newUnique)
import Data.List (intersperse)
import GHC.Generics (Generic)

data ToolCall = ToolCall
    { id :: Text
    , name :: Text
    , arguments :: HashMap Text Value }
    deriving (Eq, Generic)

instance Show ToolCall where
    show = TL.unpack . formatToolCall

formatToolCall :: ToolCall -> TL.Text
formatToolCall t =
    TLB.toLazyText $
        "ToolCall <" <> TLB.fromText t.name <> "> { " <>
        (mconcat $ intersperse (TLB.fromText ", ") $ map formatPair $ Map.toList t.arguments) <> " }"
    where
        formatPair (k, v) =
            TLB.fromText k <> " = " <>
            TLB.fromLazyText (TL.decodeUtf8 $ Aeson.encode v)

data ToolResponse = ToolResponse
    { id :: Text
    , name :: Text
    , content :: Value }
    deriving (Eq, Show)

data Message
    = SystemMessage Unique Text
    | UserMessage Unique Text
    | ToolMessage Unique ToolResponse
    | AssistantMessage Unique Text [ToolCall]
    deriving (Eq, Show)

newSystemMessage :: IOE :> es => Text -> Eff es Message
newSystemMessage prompt = do
    u <- liftIO newUnique
    pure $ SystemMessage u prompt

newUserMessage :: IOE :> es => Text -> Eff es Message
newUserMessage content = do
    u <- liftIO newUnique
    pure $ UserMessage u content

newToolMessage :: IOE :> es => ToolResponse -> Eff es Message
newToolMessage resp = do
    u <- liftIO newUnique
    pure $ ToolMessage u resp

newAssistantMessage :: IOE :> es => Text -> [ToolCall] -> Eff es Message
newAssistantMessage content toolCalls = do
    u <- liftIO newUnique
    pure $ AssistantMessage u content toolCalls

messageUnique :: Message -> Unique
messageUnique = \case
    SystemMessage u _ -> u
    UserMessage u _ -> u
    ToolMessage u _ -> u
    AssistantMessage u _ _ -> u

messageText :: Message -> Text
messageText = \case
    SystemMessage _ t -> t
    UserMessage _ t -> t
    ToolMessage _ r -> TL.toStrict $ TL.decodeUtf8 $ Aeson.encode r.content
    AssistantMessage _ t _ -> t

formatMessage :: Message -> TL.Text
formatMessage = \case
    SystemMessage _ t -> "System: " <> TL.fromStrict t
    UserMessage _ t -> "User: " <> TL.fromStrict t
    ToolMessage _ r -> TLB.toLazyText $
        "ToolResponse <" <> TLB.fromText r.name <> ">: " <>
        TLB.fromLazyText (TL.decodeUtf8 $ Aeson.encode r.content)
    AssistantMessage _ t c ->
        "Assistant: " <> TL.fromStrict t <>
        (mconcat $ map ((" " <>) . formatToolCall) c)