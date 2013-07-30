{-# LANGUAGE TemplateHaskell #-}

module Database.Relational.Schema.SQLServer (
  getType, normalizeColumn, notNull,
  columnTypeQuerySQL, primaryKeyQuerySQL
  ) where

import qualified Data.Map as Map
import qualified Database.Relational.Schema.SQLServerSyscat.Columns as Columns
import qualified Database.Relational.Schema.SQLServerSyscat.Indexes as Indexes
import qualified Database.Relational.Schema.SQLServerSyscat.IndexColumns as IndexColumns
import qualified Database.Relational.Schema.SQLServerSyscat.Types as Types

import Control.Applicative ((<|>))
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.Int (Int32, Int64)
import Data.Map (Map)
import Data.Time (LocalTime, Day, TimeOfDay)
import Database.Record.Instances ()
import Database.Relational.Query (Query, Relation, PlaceHolders, Projection,
                                  (!), (.=.), (><), asc, fromRelation, just, placeholder',
                                  query, relation', unsafeShowSql, unsafeShowSqlProjection,
                                  unsafeProjectSql, wheres)
import Database.Relational.Schema.SQLServerSyscat.Columns
import Database.Relational.Schema.SQLServerSyscat.Indexes
import Database.Relational.Schema.SQLServerSyscat.IndexColumns
import Database.Relational.Schema.SQLServerSyscat.Types
import Language.Haskell.TH (TypeQ)

--{-# ANN module "HLint: ignore Redundant $" #-}

mapFromSqlDefault :: Map String TypeQ
mapFromSqlDefault =
    Map.fromList [ ("image",         [t|ByteString|])
                 , ("text",          [t|ByteString|])
                 , ("date",          [t|Day|])
                 , ("time",          [t|TimeOfDay|])
                 , ("tinyint",       [t|Int32|])
                 , ("smallint",      [t|Int32|])
                 , ("int",           [t|Int32|])
                 , ("smalldatetime", [t|LocalTime|])
                 , ("real",          [t|Double|])
                 , ("datetime",      [t|LocalTime|])
                 , ("float",         [t|Double|])
                 , ("ntext",         [t|String|])
                 , ("bit",           [t|Char|])
                 , ("decimal",       [t|String|])
                 , ("numeric",       [t|String|])
                 , ("bigint",        [t|Int64|])
                 , ("varbinary",     [t|String|])
                 , ("varchar",       [t|String|])
                 , ("binary",        [t|ByteString|])
                 , ("char",          [t|String|])
                 , ("timestamp",     [t|LocalTime|])
                 , ("nvarchar",      [t|String|])
                 , ("nchar",         [t|String|])
                 ]

normalizeColumn :: String -> String
normalizeColumn = map toLower

notNull :: ((Columns,Types),String) -> Bool 
notNull ((cols,_),_) = isTrue . Columns.isNullable $ cols
  where
    isTrue (Just b) = not b
    isTrue _        = True

getType :: Map String TypeQ -> ((Columns,Types),String) -> Maybe (String, TypeQ)
getType mapFromSql rec@((cols,typs),typScms) = do
    colName <- Columns.name cols
    typ <- Map.lookup key mapFromSql
           <|>
           Map.lookup key mapFromSqlDefault
    return (normalizeColumn colName, mayNull typ)
  where
    key = if typScms == "sys"
            then Types.name typs
            else typScms ++ "." ++ Types.name typs
    mayNull typ = if notNull rec
                    then typ
                    else [t|Maybe $(typ)|]

sqlsrvTrue :: Projection Bool
sqlsrvTrue =  unsafeProjectSql "1"

sqlsrvObjectId :: Projection String -> Projection String -> Projection Int32
sqlsrvObjectId s t = unsafeProjectSql $
    "OBJECT_ID(" ++ unsafeShowSql s ++ " + '.' + " ++ unsafeShowSql t ++ ")"

sqlsrvOidPlaceHolder :: (PlaceHolders (String, String), Projection Int32)
sqlsrvOidPlaceHolder =  (nsParam >< relParam, oid)
  where
    (nsParam, (relParam, oid)) =
      placeholder' (\nsPh ->
                     placeholder' (\relPh ->
                                    sqlsrvObjectId nsPh relPh))

columnTypeRelation :: Relation (String,String) ((Columns,Types),String)
columnTypeRelation = relation' $ do
    cols <- query columns
    typs <- query types

    wheres $ cols ! Columns.userTypeId' .=. typs ! Types.userTypeId'
    wheres $ cols ! Columns.objectId'   .=. oid
    asc $ cols ! Columns.columnId'
    return   (params, cols >< typs >< sqlsrvSchemaName (typs ! Types.schemaId'))
  where
    (params, oid) = sqlsrvOidPlaceHolder
    sqlsrvSchemaName i = unsafeProjectSql $
        "SCHEMA_NAME(" ++ unsafeShowSqlProjection i ++ ")"

columnTypeQuerySQL :: Query (String, String) ((Columns, Types), String)
columnTypeQuerySQL = fromRelation columnTypeRelation

primaryKeyRelation :: Relation (String,String) (Maybe String)
primaryKeyRelation = relation' $ do
    idxes  <- query indexes
    idxcol <- query indexColumns 
    cols   <- query columns
    wheres $ idxes  ! Indexes.objectId'      .=. idxcol ! IndexColumns.objectId'
    wheres $ idxes  ! Indexes.indexId'       .=. idxcol ! IndexColumns.indexId'
    wheres $ idxcol ! IndexColumns.objectId' .=. cols   ! Columns.objectId'
    wheres $ idxcol ! IndexColumns.columnId' .=. cols   ! Columns.columnId'
    wheres $ idxes  ! Indexes.isPrimaryKey'  .=. just sqlsrvTrue
    let (params, oid) = sqlsrvOidPlaceHolder
    wheres $ idxes  ! Indexes.objectId'      .=. oid
    asc    $ idxcol ! IndexColumns.keyOrdinal'
    return   (params, cols   ! Columns.name')

primaryKeyQuerySQL :: Query (String,String) (Maybe String)
primaryKeyQuerySQL = fromRelation primaryKeyRelation
