-- | This helper module is intended for use by the backend creators
module Database.Groundhog.Generic
  ( migrateRecursively
  , createMigration
  , executeMigration
  , executeMigrationUnsafe
  , runMigration
  , runMigrationUnsafe
  , printMigration
  , getEntityName
  , mergeMigrations
  , silentMigrationLogger
  , defaultMigrationLogger
  , defaultSelect
  , defaultSelectAll
  ) where

import Database.Groundhog.Core

import Control.Monad(liftM, forM_)
import Control.Monad.Trans.State
import Control.Monad.Trans.Class(lift)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Enumerator(Iteratee(..), run, (==<<))
import Data.Enumerator.List(consume)
import Data.Either(partitionEithers)
import Data.List(intercalate)
import qualified Data.Map as Map

-- | Create migration for a given entity and all entities it depends on.
-- The stateful Map is used to avoid duplicate migrations when an entity type
-- occurs several times in a datatype
migrateRecursively :: (Monad m, PersistEntity e) => 
     (EntityDef -> m SingleMigration)          -- ^ migrate entity
  -> (Int -> [NamedType] -> m SingleMigration) -- ^ migrate tuple
  -> (NamedType -> m SingleMigration)          -- ^ migrate list
  -> e                                         -- ^ initial entity
  -> StateT NamedMigrations m ()
migrateRecursively migE migT migL = go . namedType where
  go w = case getType w of
    (DbList t)     -> f (getName w) (migL t) (go t)
    (DbTuple n ts) -> f (getName w) (migT n ts) (mapM_ go ts)
    (DbEntity e) -> f (getName w) (migE e) (mapM_ go (allSubtypes e))
    (DbMaybe t)    -> go t
    _              -> return ()    -- ordinary types need not migration
  f name mig cont = do
    v <- gets (Map.lookup name)
    case v of
      Nothing -> lift mig >>= modify.Map.insert name >> cont
      _ -> return ()
  allSubtypes = map snd . concatMap constrParams . constructors

getCorrectMigrations :: NamedMigrations -> [(Bool, String)]
getCorrectMigrations = either (error.unlines) id . mergeMigrations . Map.elems

-- | Produce the migrations but not execute them. Fails when an unsafe migration occurs.
createMigration :: PersistBackend m => Migration m -> m NamedMigrations
createMigration m = liftM snd $ runStateT m Map.empty

-- | Execute the migrations and log them. 
executeMigration :: (PersistBackend m, MonadIO m) => (String -> IO ()) -> NamedMigrations -> m ()
executeMigration logger m = do
  let migs = getCorrectMigrations m
  let unsafe = map snd $ filter fst migs
  if null unsafe
    then mapM_ (executeMigrate logger.snd) migs
    else error $ concat
            [ "\n\nDatabase migration: manual intervention required.\n"
            , "The following actions are considered unsafe:\n\n"
            , unlines $ map (\s -> "    " ++ s ++ ";") unsafe
            ]

-- | Execute migrations and log them. Executes the unsafe migrations without warnings
executeMigrationUnsafe :: (PersistBackend m, MonadIO m) => (String -> IO ()) -> NamedMigrations -> m ()
executeMigrationUnsafe logger = mapM_ (executeMigrate logger.snd) . getCorrectMigrations

-- | Pretty print the migrations
printMigration :: MonadIO m => NamedMigrations -> m ()
printMigration migs = liftIO $ do
  let kv = Map.assocs migs
  forM_ kv $ \(k, v) -> do
    putStrLn $ "Datatype " ++ k ++ ":"
    case v of
      Left errors -> mapM_ (putStrLn . ("\tError:\t" ++)) errors
      Right sqls  -> do
        let showSql (isUnsafe, sql) = (if isUnsafe then "Unsafe:\t" else "Safe:\t") ++ sql
        mapM_ (putStrLn . ("\t" ++).showSql) sqls

-- | Run migrations and log them. Fails when an unsafe migration occurs.
runMigration :: (PersistBackend m, MonadIO m) => (String -> IO ()) -> Migration m -> m ()
runMigration logger m = createMigration m >>= executeMigration logger

-- | Run migrations and log them. Executes the unsafe migrations without warnings
runMigrationUnsafe :: (PersistBackend m, MonadIO m) => (String -> IO ()) -> Migration m -> m ()
runMigrationUnsafe logger m = createMigration m >>= executeMigrationUnsafe logger

executeMigrate :: (PersistBackend m, MonadIO m) => (String -> IO ()) -> String -> m ()
executeMigrate logger query = do
  liftIO $ logger query
  executeRaw False query []
  return ()

-- | No-op
silentMigrationLogger :: String -> IO ()
silentMigrationLogger _ = return ()

-- | Prints the queries to stdout
defaultMigrationLogger :: String -> IO ()
defaultMigrationLogger query = putStrLn $ "Migrating: " ++ query

-- | Joins the migrations. The result is either all error messages or all queries
mergeMigrations :: [SingleMigration] -> SingleMigration
mergeMigrations ms =
  let (errors, statements) = partitionEithers ms
  in if null errors
       then Right (concat statements)
       else Left  (concat errors)

-- | Get full entity name with the names of its parameters.
--
-- @ getEntityName (entityDef v) == persistName v @
getEntityName :: EntityDef -> String
getEntityName e = intercalate "$" $ entityName e:map getName (typeParams e)

-- | Call 'selectEnum' but return the result as a list
defaultSelect :: (PersistBackend m, PersistEntity v, Constructor c) => Cond v c -> [Order v c] -> Int -> Int -> m [(Key v, v)]
defaultSelect cond ord off lim = do
    res <- run $ selectEnum cond ord off lim ==<< consume
    case res of
        Left e -> error $ show e
        Right x -> return x

-- | Call 'selectAllEnum' but return the result as a list
defaultSelectAll :: (PersistBackend m, PersistEntity v) => m [(Key v, v)]
defaultSelectAll = do
    res <- run $ Iteratee (runIteratee consume >>= runIteratee . selectAllEnum)
    case res of
        Left e -> error $ show e
        Right x -> return x
