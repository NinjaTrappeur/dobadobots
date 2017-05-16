{-# LANGUAGE OverloadedStrings #-}

module DobadoBots.GameEngine.Data (
  Size(..)
, Position(..)
, Velocity(..)
, GameState(..)
, Object(..)
, Obstacle(..)
, Objective(..)
, StartingPoint(..)
, Robot(..)
, Collider(..)
, getCenter
) where

import Linear.V2 (V2(..))
import Data.Aeson (FromJSON(..), withObject, (.:)) 
import Data.Sequence (Seq)
import qualified Data.Aeson.Types as AT (Parser, Object(..), Value(..)) 
import qualified Data.HashMap.Lazy as HS (lookup)

type Size = V2 Float 

type Position = V2 Float

type Velocity = Float

data GameState = GameState   {obstacles      :: [Obstacle]
                            , arenaSize      :: Size
                            , objective      :: Objective
                            , startingPoints :: [StartingPoint]
                            , robots         :: Seq Robot} deriving (Show, Eq)

data Object = Object {position :: Position
                    , size     :: Size
                    , rotation :: Float
                    , velocity :: Velocity} deriving (Show, Eq)

data Collider = Obstacle | Objective | Wall | Robot deriving (Show)

type Obstacle = Object

type Objective = Object

type StartingPoint = Object

type Robot = Object 

instance FromJSON GameState where
  parseJSON = withObject "GameState" $ \v -> GameState
    <$> v .: "obstacles"
    <*> pure (V2 640 480)
    <*> v .: "objective"
    <*> v .: "startingpoints"
    <*> v .: "startingpoints"

instance FromJSON Object where
    parseJSON = withObject  "Object" $ \v -> Object
      <$> parsePosition (HS.lookup "position" v) 
      <*> parseSize (HS.lookup "size" v) 
      <*> v .: "rotation"
      <*> v .: "velocity"

parsePosition :: Maybe AT.Value -> AT.Parser (V2 Float)
parsePosition (Just (AT.Object v)) = V2 <$> v .: "x" <*> v .: "y"
parsePosition _ = fail "No position object."

parseSize :: Maybe AT.Value -> AT.Parser (V2 Float)
parseSize (Just(AT.Object v)) = V2 <$> v .: "width" <*> v .: "height"
parseSize _ = fail "No size object."

getCenter :: Object -> Position
getCenter o = position o + (size o / 2)
