{-# LANGUAGE RequiredTypeArguments #-}

module Heco.Effectful.DatabaseService.Milvus
    ( -- * Data types
      MilvusOps(..)
    , milvusOps
      -- * Database API
    , runMilvusDatabaseService
    , runMilvusDatabaseServiceEx
    ) where

import Heco.Network.HTTP.Client (httpPost)
import Heco.Data.Aeson (defaultAesonOps)
import Heco.Data.Entity (EntityId(..), IsEntityData, Entity (entityDataFields))
import Heco.Data.DatabaseError (DatabaseError(DatabaseBackendError))
import Heco.Data.Collection (CollectionName(CollectionName))
import Heco.Events.DatabaseEvent (DatabaseEvent(..))
import Heco.Effectful.DatabaseService (DatabaseService(..), CollectionLoadState(..), QueryOps(..), SearchOps(..))
import Heco.Effectful.Event (Event, trigger, runEvent)

import Effectful (IOE, (:>), Eff, MonadIO (liftIO))
import Effectful.Exception (catchIO)
import Effectful.Dispatch.Dynamic (HasCallStack, reinterpret)
import Effectful.Error.Dynamic (Error, throwError, runError, CallStack)
import Effectful.Reader.Static (runReader, ask, Reader)

import Network.HTTP.Client
    ( responseTimeoutMicro,
      httpLbs,
      defaultManagerSettings,
      newManager,
      Manager,
      ManagerSettings(managerResponseTimeout),
      Response(responseBody) )

import Data.Text (Text)
import Data.Text qualified as T
import Data.ByteString (ByteString)

import Data.Aeson qualified as Aeson
import Data.Aeson (ToJSON, FromJSON)
import Data.Aeson.TH (deriveToJSON1, deriveFromJSON, deriveToJSON)

import Data.Vector (Vector)
import Data.Vector qualified as V
import Data.Vector.Unboxing qualified as VU

import GHC.Records (HasField)

data MilvusOps = MilvusOps
    { hostUrl :: Text
    , timeout :: Int
    , token :: Maybe ByteString
    , database :: Maybe Text }

milvusOps :: Text -> MilvusOps
milvusOps url = MilvusOps
    { hostUrl = url
    , timeout = 15
    , token = Nothing
    , database = Nothing }

data MilvusCollectionOps = MilvusCollectionOps
    { dbName :: Maybe Text
    , collectionName :: Text }

data MilvusCollectionResp = MilvusCollectionResp
    { code :: Int
    , message :: Maybe Text }

deriveToJSON defaultAesonOps ''MilvusCollectionOps
deriveFromJSON defaultAesonOps ''MilvusCollectionResp

data MilvusStatusData = MilvusStatusData
    { loadState :: Text
    , loadProgress :: Int
    , message :: Maybe Text }

data MilvusStatusResp = MilvusStatusResp
    { code :: Int
    , message :: Maybe Text
    , _data :: Maybe MilvusStatusData }

deriveFromJSON defaultAesonOps ''MilvusStatusData
deriveFromJSON defaultAesonOps ''MilvusStatusResp

data MilvusGetStatsData = MilvusGetStatsData
    { rowCount :: Int }

data MilvusGetStatsResp = MilvusGetStatsResp
    { code :: Int
    , message :: Maybe Text
    , _data :: Maybe MilvusGetStatsData }

deriveFromJSON defaultAesonOps ''MilvusGetStatsData
deriveFromJSON defaultAesonOps ''MilvusGetStatsResp

data MilvusInsertOps e = MilvusInsertOps
    { dbName :: Maybe Text
    , collectionName :: Text
    , _data :: Vector e }

data MilvusInsertData = MilvusInsertData
    { insertIds :: VU.Vector EntityId }

data MilvusInsertResp = MilvusInsertResp
    { code :: Int
    , message :: Maybe Text
    , _data :: Maybe MilvusInsertData }

data MilvusUpsertData = MilvusUpsertData
    { upsertIds :: VU.Vector EntityId }

data MilvusUpsertResp = MilvusUpsertResp
    { code :: Int
    , message :: Maybe Text
    , _data :: Maybe MilvusUpsertData }

getInsertDataIds :: MilvusInsertResp -> Maybe (VU.Vector EntityId)
getInsertDataIds r = fmap (\d -> d.insertIds) r._data

getUpsertDataIds :: MilvusUpsertResp -> Maybe (VU.Vector EntityId)
getUpsertDataIds r = fmap (\d -> d.upsertIds) r._data

deriveToJSON1 defaultAesonOps ''MilvusInsertOps
deriveFromJSON defaultAesonOps ''MilvusInsertData
deriveFromJSON defaultAesonOps ''MilvusInsertResp
deriveFromJSON defaultAesonOps ''MilvusUpsertData
deriveFromJSON defaultAesonOps ''MilvusUpsertResp

data MilvusGetOps = MilvusGetOps
    { dbName :: Maybe Text
    , collectionName :: Text
    , id :: VU.Vector EntityId
    , outputFields :: [Text] }

data MilvusGetResp e = MilvusGetResp
    { code :: Int
    , message :: Maybe Text
    , _data :: Maybe (Vector e) }

deriveToJSON defaultAesonOps ''MilvusGetOps
deriveFromJSON defaultAesonOps ''MilvusGetResp

data MilvusQueryOps = MilvusQueryOps
    { dbName :: Maybe Text
    , collectionName :: Text
    , filter :: Text
    , limit :: Maybe Int
    , offset :: Maybe Int
    , outputFields :: [Text] }

deriveToJSON defaultAesonOps ''MilvusQueryOps

data MilvusSearchExtraParams = MilvusSearchExtraParams
    { radius :: Maybe Int
    , range_filter :: Maybe Int }

data MilvusSearchParams = MilvusSearchParams
    { params :: MilvusSearchExtraParams }

data MilvusSearchOps = MilvusSearchOps
    { dbName :: Maybe Text
    , collectionName :: Text
    , _data :: [VU.Vector Float]
    , annsField :: Text
    , searchParams :: Maybe MilvusSearchParams
    , filter :: Maybe Text
    , limit :: Maybe Int
    , offset :: Maybe Int
    , outputFields :: [Text] }

deriveToJSON defaultAesonOps ''MilvusSearchExtraParams
deriveToJSON defaultAesonOps ''MilvusSearchParams
deriveToJSON defaultAesonOps ''MilvusSearchOps

data MilvusDeleteOps = MilvusDeleteOps
    { dbName :: Maybe Text
    , collectionName :: Text
    , filter :: Text }

deriveToJSON defaultAesonOps ''MilvusDeleteOps

getMilvusSearchParams :: SearchOps -> Maybe MilvusSearchParams
getMilvusSearchParams ops = get ops.radius ops.rangeFilter
    where
        get Nothing Nothing = Nothing
        get r f = Just $ MilvusSearchParams
            { params = MilvusSearchExtraParams
                { radius = r
                , range_filter = f } }

safeLiftIO :: (Error DatabaseError :> es, IOE :> es) => IO a -> Eff es a
safeLiftIO m = liftIO m
    `catchIO` (throwError . DatabaseBackendError . show)

throwErrorCode :: (HasCallStack, Error DatabaseError :> es) => Int -> Text -> Eff es a
throwErrorCode code msg =
    throwError $ DatabaseBackendError $ show msg ++ "; code: " ++ show code

throwInvalidResponseError :: (HasCallStack, Error DatabaseError :> es) => Eff es a
throwInvalidResponseError =
    throwError $ DatabaseBackendError $ "invalid response"

throwInvalidResponseErrorCode :: (HasCallStack, Error DatabaseError :> es) => Int -> Eff es a
throwInvalidResponseErrorCode code =
    throwError $ DatabaseBackendError $ "invalid response; code: " ++ show code

type IsMilvusResponse resp =
    ( FromJSON resp
    , HasField "message" resp (Maybe Text)
    , HasField "code" resp Int )

guardResponse ::
    ( HasCallStack
    , IsMilvusResponse resp
    , Error DatabaseError :> es )
    => resp -> Eff es ()
guardResponse resp =
    case resp.message of
        Just err | T.length err /= 0 -> throwErrorCode resp.code err
        _ -> pure ()

milvusPost :: forall resp req es.
    ( HasCallStack
    , ToJSON req, IsMilvusResponse resp
    , IOE :> es
    , Reader Manager :> es
    , Error DatabaseError :> es )
    => MilvusOps -> Text -> req -> Eff es resp
milvusPost ops url req = do
    manager <- ask
    resp <- safeLiftIO do
        req' <- httpPost (ops.hostUrl <> url) headers req
        responseBody <$> httpLbs req' manager
    case Aeson.eitherDecode @resp resp of
        Left e -> throwError $ DatabaseBackendError e
        Right r -> guardResponse r >> pure r
    where
        headers = ("Content-Type", "application/json") :
            maybe [] (\t -> [("Authorization", "Bearer " <> t)]) ops.token

collectionRequest ::
    ( HasCallStack
    , IsMilvusResponse resp
    , IOE :> es
    , Reader Manager :> es
    , Error DatabaseError :> es )
    => MilvusOps -> Text -> CollectionName -> Eff es resp
collectionRequest ops url (CollectionName col) = do
    resp <- milvusPost ops url
        MilvusCollectionOps
            { dbName = ops.database
            , collectionName = col }
    pure resp

collectionRequest_ ::
    ( HasCallStack
    , Reader Manager :> es
    , IOE :> es
    , Error DatabaseError :> es )
    => MilvusOps -> Text -> CollectionName -> Eff es ()
collectionRequest_ ops url col =
    collectionRequest @MilvusCollectionResp ops url col >> pure ()

setEntitiesImpl ::
    ( HasCallStack
    , IsEntityData e
    , IsMilvusResponse resp
    , IOE :> es
    , Reader Manager :> es
    , Event DatabaseEvent :> es
    , Error DatabaseError :> es )
    => MilvusOps -> Text -> CollectionName -> (resp -> Maybe (VU.Vector EntityId)) -> Vector e
    -> Eff es (VU.Vector EntityId)
setEntitiesImpl ops url (CollectionName col) idsGetter es = do
    resp <- milvusPost ops url
        $ Aeson.toJSON1 MilvusInsertOps
            { dbName = ops.database
            , collectionName = col
            , _data = es }
    case idsGetter resp of
        Nothing -> throwInvalidResponseErrorCode resp.code
        Just ids -> do
            V.forM_ es $ trigger . OnDatabaseEntityUpdated
            pure ids

getEntitiesImpl :: forall e es.
    ( HasCallStack
    , Entity e
    , IOE :> es
    , Reader Manager :> es
    , Error DatabaseError :> es )
    => MilvusOps -> CollectionName -> VU.Vector EntityId -> Eff es (Vector e)
getEntitiesImpl ops (CollectionName col) ids = do
    resp <- milvusPost @(MilvusGetResp e) ops "/v2/vectordb/entities/get"
        MilvusGetOps
            { dbName = ops.database
            , collectionName = col
            , id = ids
            , outputFields = "id" : entityDataFields @e }
    case resp._data of
        Nothing -> throwInvalidResponseError
        Just es -> pure es

runMilvusDatabaseService ::
    (HasCallStack, IOE :> es, Event DatabaseEvent :> es, Error DatabaseError :> es)
    => MilvusOps
    -> Eff (DatabaseService : es) a
    -> Eff es a
runMilvusDatabaseService ops = reinterpret evalServiceState \_ -> \case
    LoadCollection col -> do
        collectionRequest_ ops "/v2/vectordb/collections/load" col
        trigger $ OnDatabaseCollectionLoaded col

    RefreshLoadCollection col -> do
        collectionRequest_ ops "/v2/vectordb/collections/refresh_load" col
        trigger $ OnDatabaseCollectionLoaded col

    ReleaseCollection col -> do
        collectionRequest_ ops "/v2/vectordb/collections/release" col
        trigger $ OnDatabaseCollectionReleased col
    
    FlushCollection col -> do
        collectionRequest_ ops "/v2/vectordb/collections/flush" col
        trigger $ OnDatabaseCollectionFlushed col

    CompactCollection col -> do
        collectionRequest_ ops "/v2/vectordb/collections/compact" col
        trigger $ OnDatabaseCollectionCompacted col

    GetCollectionLoadState col -> do
        resp <- collectionRequest @MilvusStatusResp ops "/v2/vectordb/collections/get_load_state" col
        case resp._data of
            Nothing -> throwInvalidResponseError
            Just d -> pure CollectionLoadState
                { state = d.loadState
                , progress = d.loadProgress
                , message = maybe "" id d.message }
    
    GetEntityCount col -> do
        resp <- collectionRequest @MilvusGetStatsResp ops "/v2/vectordb/collections/get_stats" col
        case resp._data of
            Nothing -> throwInvalidResponseError
            Just d -> pure d.rowCount
    
    AddEntities col es ->
        setEntitiesImpl ops insertionUrl col getInsertDataIds es

    AddEntity col e -> do
        r <- setEntitiesImpl ops insertionUrl col getInsertDataIds $ V.singleton e
        if VU.length r == 0
            then throwInvalidResponseError
            else pure $ r VU.! 0

    SetEntities col es ->
        setEntitiesImpl ops upsertionUrl col getUpsertDataIds es

    SetEntity col e -> do
        r <- setEntitiesImpl ops upsertionUrl col getUpsertDataIds $ V.singleton e
        if VU.length r == 0
            then throwInvalidResponseError
            else pure $ r VU.! 0
    
    GetEntities col ids ->
        getEntitiesImpl ops col ids
    
    GetEntity col id -> do
        r <- getEntitiesImpl ops col $ VU.singleton id
        if V.length r == 0
            then throwInvalidResponseError
            else pure $ r V.! 0
    
    QueryEntities @e (CollectionName col) queryOps -> do
        resp <- milvusPost @(MilvusGetResp e) ops "/v2/vectordb/entities/query"
            MilvusQueryOps
                { dbName = ops.database
                , collectionName = col
                , filter = queryOps.filter
                , limit = queryOps.limit
                , offset = queryOps.offset
                , outputFields = "id" : entityDataFields @e }
        case resp._data of
            Nothing -> throwInvalidResponseError
            Just es -> pure es
    
    SearchEntities @e (CollectionName col) searchOps -> do
        resp <- milvusPost @(MilvusGetResp e) ops "/v2/vectordb/entities/search"
            MilvusSearchOps
                { dbName = ops.database
                , collectionName = col
                , _data = searchOps.vectors
                , annsField = "vector"
                , searchParams = getMilvusSearchParams searchOps
                , filter = searchOps.filter
                , limit = searchOps.limit
                , offset = searchOps.offset
                , outputFields = "id" : entityDataFields @e }
        case resp._data of
            Nothing -> throwInvalidResponseError
            Just es -> pure es
    
    DeleteEntities (CollectionName col) filter -> do
        _ <- milvusPost @MilvusCollectionResp ops "/v2/vectordb/entities/delete"
            MilvusDeleteOps
                { dbName = ops.database
                , collectionName = col
                , filter = filter }
        pure ()

    where
        evalServiceState e = do
            manager <- liftIO $ newManager defaultManagerSettings
                { managerResponseTimeout =
                    responseTimeoutMicro $ ops.timeout * 1000000 }
            runReader manager e

        insertionUrl = "/v2/vectordb/entities/insert" :: Text
        upsertionUrl = "/v2/vectordb/entities/upsert" :: Text

runMilvusDatabaseServiceEx ::
    (HasCallStack, IOE :> es)
    => MilvusOps
    -> Eff (DatabaseService : Event DatabaseEvent : Error DatabaseError : es) a
    -> Eff es (Either (CallStack, DatabaseError) a)
runMilvusDatabaseServiceEx ops = 
    runError . runEvent . runMilvusDatabaseService ops