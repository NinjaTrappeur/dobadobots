{-# LANGUAGE OverloadedStrings #-}
module DobadoBots.Graphics.Renderer (
  mainGraphicsLoop
, createRendererState 
, handleEvents
) where

import DobadoBots.GameEngine.Data          (GameState(..), Objective(..), 
                                            Obstacle(..), GamePhase(..),
                                            Object(..), Robot(..), 
                                            getCenter)
import DobadoBots.GameEngine.GameEngine    (reinitGameState, getAvailableLevels)
import DobadoBots.GameEngine.Utils         (setPhase, setLevel)
import DobadoBots.Graphics.Editor          (drawEditor, renderCode,
                                            appendEventEditor, handleEditorEvents,
                                            prettyPrintAst)
import DobadoBots.Graphics.Utils           (loadFontBlended, getBmpTex, setLevelNumber)
import DobadoBots.Graphics.Data            (RendererState(..), ButtonEvent(..), EditorState(..))
import DobadoBots.Graphics.Buttons         (createButtons, displayButtons, handleMouseEvents)
import DobadoBots.Interpreter.Data         (Cond, Collider(..))
import DobadoBots.Interpreter.Parser       (parseScript)

import GHC.Float                           (float2Double)
import qualified SDL                       (Renderer, rendererDrawColor, clear,
                                            present, fillRects, fillRect, 
                                            Rectangle(..), Point(..), V2(..), 
                                            V4(..), Texture(..),
                                            createTextureFromSurface, 
                                            freeSurface, copyEx, drawLine, copy,
                                            surfaceDimensions, Event, ticks)
import qualified SDL.TTF as TTF            (withInit, wasInit,
                                            openFont, renderUTF8Solid,
                                            renderUTF8Blended, closeFont)
import SDL                                 (($=))
import qualified SDL.Raw as Raw            (Color(..))
import qualified Linear.V2 as L            (V2(..))
import qualified Linear.Metric as LM       (distance)
import Foreign.C.Types                     (CInt(..), CDouble(..))
import           Control.Monad             (unless, when, liftM2, mapM) 
import qualified Data.Vector.Storable as V (Vector(..), fromList, map) 
import qualified Data.Sequence as S        (Seq)
import qualified Data.HashMap.Strict as HM (lookup, elems)
import           Data.Maybe                (fromMaybe)
import qualified Data.Text as T            (lines, unlines)
import           Data.Either.Extra         (fromRight, isLeft)
import           Text.Parsec               (ParseError)

mainGraphicsLoop :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainGraphicsLoop renderer gameState rendererState = do 
  SDL.rendererDrawColor renderer $= SDL.V4 14 36 57 maxBound
  SDL.clear renderer
  ticks <- SDL.ticks
  case phase gameState of
    SplashScreen   -> mainLoopSplash  renderer gameState rendererState
    LevelSelection -> mainLoopLevelSelection renderer gameState rendererState
    Running        -> mainLoopRunning renderer gameState rendererState
    Editing        -> mainLoopEditing renderer gameState rendererState
    Win            -> mainLoopWin renderer gameState rendererState
  SDL.present renderer
  return ()

mainLoopLevelSelection :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainLoopLevelSelection renderer gameState rendererState = do
  drawEditor renderer gameState rendererState
  drawArena renderer gameState
  nrst <- setLevelNumber renderer rendererState 
  let pos = SDL.P $ SDL.V2 290 365
  SDL.copy renderer (fst $ levelNumber nrst) Nothing (Just $ SDL.Rectangle pos (snd $ levelNumber nrst))
  drawRobots renderer (robotTexture nrst) . HM.elems $ robots gameState 
  displayButtons renderer (buttons nrst)
  return ()

mainLoopSplash :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainLoopSplash r gst rst = do 
  SDL.copy r spTex Nothing (Just $ SDL.Rectangle (SDL.P $ SDL.V2 0 0) sizeTex)
  displayButtons r (buttons rst)
  return ()
  where
    spTex   = fst $ splashScreen rst
    sizeTex = snd $ splashScreen rst

mainLoopRunning :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainLoopRunning renderer gameState rendererState = do
  drawEditor renderer gameState rendererState
  drawArena renderer gameState
  drawLines renderer gameState
  drawRobots renderer (robotTexture rendererState) . HM.elems $ robots gameState 
  displayButtons renderer (buttons rendererState)
  mapM_ (drawRobotDist renderer gameState ) $ robots gameState

mainLoopWin :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainLoopWin renderer gameState rst = do
  (fontTex, size) <- loadFontBlended renderer
                        "data/fonts/Inconsolata-Regular.ttf"
                        30
                        (Raw.Color 255 255 255 0)
                        "You won (TODO better splashscreen)"
  let pos = SDL.P $ SDL.V2 100 200
  SDL.rendererDrawColor renderer $= SDL.V4 171 11 11 maxBound
  SDL.copy renderer fontTex Nothing (Just $ SDL.Rectangle pos size)

mainLoopEditing :: SDL.Renderer -> GameState -> RendererState -> IO ()
mainLoopEditing renderer gameState rendererState = do
  drawEditor renderer gameState rendererState
  drawArena renderer gameState
  drawRobots renderer (robotTexture rendererState) . HM.elems $ robots gameState 
  displayButtons renderer (buttons rendererState)
  return ()

-- NOTE this function is a real mess. It should be properly
-- refactored. I think we first should about a proper stream model.
handleEvents :: SDL.Renderer -> [SDL.Event] -> RendererState -> GameState -> (RendererState, GameState)
handleEvents r evts rst st = (nrst, nst)
  where (brst, bst) = handleMouseEvents evts rst
        nst  = GameState 
                (obstacles bnst)
                (arenaSize bnst)
                (objective bnst)
                (startingPoints bnst)
                (robots bnst)
                (phase bnst)
                (collisions bnst)
                nAst
        nrst  = RendererState 
                  (levels nBrst)
                  (currentSelectedLvl nBrst)
                  (robotTexture nBrst)
                  (editorCursor nBrst)
                  (codeTextures nBrst)
                  (running nBrst)
                  (editing nBrst) 
                  (buttons nBrst)
                  (parseErrorMess nBrst)
                  (parseErrorCursor nBrst)
                  (splashScreen nBrst)
                  (levelNumber nBrst)
                  nEditorState
                  parseResult
        bnst = case bst of
                Just StartEvent -> setPhase Running st
                Just EditEvent  -> setPhase Editing $ reinitGameState st
                Just PlayEvent  -> setPhase LevelSelection st
                Just ChoseLevelEvent -> setPhase Editing $ reinitGameState st
                Just LeftEvent  -> setLevel (levels nBrst !! currentSelectedLvl nBrst) st
                Just RightEvent -> setLevel (levels nBrst !! currentSelectedLvl nBrst) st
                _ -> st
        nBrst = fromMaybe rst brst
        nEditorState = if astChanged
                       then EditorState 
                              (T.unlines $ prettyPrintAst nAst) 
                              (cursorColumn unformatedEdSt) 
                              (cursorLine   unformatedEdSt)
                       else unformatedEdSt
        astChanged   = ast st /= nAst
        nAst         = fromRight (ast st) parseResult
        parseResult  =  parseScript . text $ unformatedEdSt
        unformatedEdSt = fromMaybe (editor rst) appEdSt
        appEdSt      = liftM2 appendEventEditor editorEvt (Just $ editor rst)
        editorEvt    = if phase st == Editing
                       then handleEditorEvents evts
                       else Nothing

drawRobotDist :: SDL.Renderer -> GameState -> Robot -> IO ()
drawRobotDist r st rb = do
  (fontTex, size) <- loadFontBlended r
                        "data/fonts/Inconsolata-Regular.ttf"
                        12
                        (Raw.Color 255 255 255 0) 
                        ( show (fst target)++ " | " ++ (show . floor $ distance ))
  let middle = SDL.P $ linearToSDLV2 $ ((posTarget + posRob) / 2) - (sdlv2ToLinear size / 2)
  let loc = SDL.Rectangle middle size
  SDL.rendererDrawColor r $= SDL.V4 171 11 11 maxBound
  when (distance > 80) $ do
    SDL.fillRect r (Just $ SDL.Rectangle middle (size + padding * 2 ))
    SDL.copy r fontTex Nothing (Just $ SDL.Rectangle (textP middle) size)
  where posRob           = position $ object rb
        target           = case lookup of
                             (Just val) -> val
                             Nothing    -> (Wall, posRob)
        posTarget        = snd target
        lookup           = HM.lookup (robotId rb) $ collisions st
        distance         = LM.distance posRob posTarget
        padding          = 2
        textP (SDL.P v)  = SDL.P (v + padding)

drawLines :: SDL.Renderer -> GameState -> IO ()
drawLines r s = do
  drawObjectiveLine r (HM.elems $ robots s) (objective s)
  SDL.rendererDrawColor r $= SDL.V4 255 0 0 maxBound
  drawRobotsFrontLine r (HM.elems $ robots s) s

drawRobotsFrontLine :: SDL.Renderer -> [Robot] -> GameState -> IO ()
drawRobotsFrontLine r rbs st = mapM_ drawRbFrontLine rbs
  where
    drawRbFrontLine rb = SDL.drawLine r (pRobot rb) (pFront rb)
    pRobot rb = SDL.P . linearToSDLV2 . getCenter $ object rb
    pFront rb = case nearestInt $ robotId rb of
        Nothing -> pRobot rb
        (Just int) -> SDL.P . linearToSDLV2 . snd $ int
    nearestInt rbId = HM.lookup rbId $ collisions st

drawObjectiveLine :: SDL.Renderer -> [Robot] -> Objective -> IO ()
drawObjectiveLine r rbs o = mapM_ drawRbLine rbs
  where
    drawRbLine rb = SDL.drawLine r (pRobot rb) pObjective
    pRobot rb     = SDL.P . linearToSDLV2 . getCenter $ object rb
    pObjective    = SDL.P . linearToSDLV2 $ getCenter o

drawArena :: SDL.Renderer -> GameState -> IO ()
drawArena renderer gameState = do
  let obsR = getObstaclesRects $ obstacles gameState
  let objR = getObjectiveRect $ objective gameState
  SDL.rendererDrawColor renderer $= SDL.V4 42 84 126 maxBound
  SDL.fillRects renderer obsR
  SDL.rendererDrawColor renderer $= SDL.V4 255 88 0 maxBound
  SDL.fillRect renderer $ Just objR

getObstaclesRects :: [Obstacle] -> V.Vector (SDL.Rectangle CInt)
getObstaclesRects obs = V.fromList rectangles 
  where
    rectangles   = map rectangle obs
    rectangle ob = SDL.Rectangle (pointRect ob) (sizeRect ob)
    pointRect ob = SDL.P . linearToSDLV2 $ position ob
    sizeRect ob  = linearToSDLV2 $ size ob

getObjectiveRect :: Objective -> SDL.Rectangle CInt
getObjectiveRect obj  = SDL.Rectangle (pointRect obj) (sizeRect obj)
  where pointRect obj = SDL.P . linearToSDLV2 $ position obj
        sizeRect obj  = linearToSDLV2 $ size obj
  
drawRobot :: SDL.Renderer -> (SDL.Texture, SDL.V2 CInt) -> Robot -> IO ()
drawRobot renderer tex robot = SDL.copyEx renderer (fst tex) Nothing (Just dest) angle Nothing (SDL.V2 False False)
  where 
        angle = CDouble . float2Double . rotation $ object robot
        dest  = SDL.Rectangle p s
        p     = SDL.P . linearToSDLV2 . position $ object robot
        s     = linearToSDLV2 . size $ object robot

drawRobots :: SDL.Renderer -> (SDL.Texture, SDL.V2 CInt) -> [Robot] -> IO()
drawRobots r t = mapM_ (drawRobot r t)

linearToSDLV2 :: L.V2 Float -> SDL.V2 CInt
linearToSDLV2 (L.V2 x y) = SDL.V2 (toCint x) (toCint y)  

sdlv2ToLinear :: SDL.V2 CInt -> L.V2 Float
sdlv2ToLinear (SDL.V2 x y) = L.V2 (cIntToFloat x) (cIntToFloat y)
  where cIntToFloat = fromIntegral . toInteger

toCint :: Float -> CInt
toCint x = CInt $ floor x

createRendererState :: FilePath -> SDL.Renderer -> GameState -> Cond -> IO RendererState
createRendererState robotImg renderer st ast = do
  robot <- getBmpTex robotImg renderer 
  codeTex <- renderCode renderer $ prettyPrintAst ast 
  buttons <- createButtons renderer
  running <- getBmpTex "data/img/running.bmp" renderer
  editing <- getBmpTex "data/img/editing.bmp" renderer
  splash  <- getBmpTex "data/img/splash.bmp"  renderer
  cursor  <- loadFontBlended renderer "data/fonts/Inconsolata-Regular.ttf" 12 (Raw.Color 0 255 0 0) "|"
  errorCursor <- loadFontBlended renderer "data/fonts/Inconsolata-Regular.ttf" 12 (Raw.Color 255 255 255 0) "!"
  levelNumber <- loadFontBlended renderer "data/fonts/Inconsolata-Regular.ttf" 14 (Raw.Color 255 255 255 0) "Level 1"
  levels <- getAvailableLevels "data/levels"
  let editorSt = EditorState (T.unlines $ prettyPrintAst ast) 0 0
  return $ RendererState levels 0 robot cursor codeTex running editing buttons [] errorCursor splash levelNumber editorSt (Right ast)
