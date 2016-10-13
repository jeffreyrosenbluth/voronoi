{-# LANGUAGE StrictData #-}
{-# OPTIONS_HADDOCK ignore-exports #-}
module Fortune
  ( voronoi
  , Point (..)
  , Edge (..)
  )
where

import Debug.Trace (trace, traceShow)


import Breakpoints


import Control.Arrow ((***))

import Data.List (findIndex, findIndices, elemIndex, sortOn)

import Data.Maybe (fromJust, maybeToList, catMaybes)

import qualified  Data.Vector.Unboxed as V
import qualified Data.Map.Strict as Map


type Index = Int

type Point a = (a, a)


type NewPointEvent = Index
data CircleEvent a = CircleEvent Index Index Index a (Point a) deriving Show

--data Event a = NewPoint Index (Point a)
--           | CircleEvent Index Index Index a (Point a)
--           deriving Show

data Type = L | R deriving Show

--data Breakpoint a = Breakpoint Index Index a Type deriving Show

data IEdge a = PlaceHolder | IEdge (Point a) deriving Show
data Edge a = Edge Index Index (Point a) (Point a) deriving Show

data State a = State
  {
    spoints :: V.Vector (Point a)
  , snewpointevents :: V.Vector NewPointEvent
  , scircleevents :: [CircleEvent a]
  , sbreaks :: BTree
  , sedges  :: Map.Map (Index, Index) (IEdge a)
  , sfinaledges :: [Edge a]
  , sfirst  :: Index
  , sprevd  :: a
  } deriving Show



{- |
    Generate the voronoi diagram (defined by a set of edges) corresponding to
    the given list of centers.
-}
voronoi :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => [Point a] -> [Edge a]
voronoi points =
  let
    go :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => State a -> [Edge a]
    go state = if V.null (snewpointevents state) && null (scircleevents state) then
        sfinaledges $ finish state
        --sedges state
      else
        go (nextEvent state)
  in
    go $ mkState points



-- * Private methods
-- ** Manipulating events


{- |
    > removeCEvent i j k events
    Remove a CircleEvent identified by the 3 indexes /i j k/ from /events/.
-}
removeCEvent :: (Show a, Floating a, RealFrac a) => Index -> Index -> Index -> [CircleEvent a] 
             -> [CircleEvent a]
removeCEvent i j k events =
  let
    removeFromList x xs = let (ls,rs) = splitAt x xs in ls ++ tail rs
    index = findIndex search events
    search (CircleEvent i' j' k' _ _) = [i',j',k'] == [i,j,k]
  in
   case index of
     Nothing -> events
     Just idx -> removeFromList idx events

{- |
    > insertEvents newEvents events
    Inserts each Event in /newEvents/ into /events/, keeping the list sorted.
 -}
insertEvents :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a)
             =>[CircleEvent a] -> [CircleEvent a] -> [CircleEvent a]
insertEvents news events =
  let
    insertEvent new events' = 
      let
        CircleEvent _ _ _ y _ = new
        (ls, rs) = span (\(CircleEvent _ _ _ y' _) -> y' < y) events'
      in
        if y /= 0 then
          ls ++ new : rs
        else
          events'
  in
    foldr insertEvent events news


-- ** Breakpoints

indexAtLeftOf :: Breakpoint -> Index
indexAtLeftOf = fst

indexAtRightOf :: Breakpoint -> Index
indexAtRightOf = snd


{- |
    > joinBreakpoints p i breaks
    Join breakpoint /i/ and /i+1/ at the point /p/. Joining two breakpoints
    results in a new breakpoint, with a corresponding new edge, and possible new
    events, as well as potentially events that need to be removed.
-}
joinBreakpoints :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) 
                => Point a -> Index -> Index -> Index -> a -> a -> BTree -> V.Vector (Point a)
                -> (BTree
                   , [CircleEvent a], [(Index, Index, Index)])
joinBreakpoints p i j k d d' breaks points =
  let
    newbreaks = joinPairAt (fst p) i j k d d' points breaks
--    newedge = edge i k (-1, -1) p
    
    prev = inOrderPredecessor (updateBreakpoint (i, j) points d') (i, j) d' points breaks
    next = inOrderSuccessor (updateBreakpoint (j, k) points d') (j, k) d' points breaks

{-
    -- TESTING
    ordered = fmap snd $ inorder breaks
    index = elemIndex (i, j) ordered
    index2 = elemIndex (j, k) ordered
    prevtest = case index of
      Nothing -> (0, 0)
      Just idx -> if idx > 0 then ordered !! (idx - 1) else (0,0)
    nexttest = case index2 of
      Nothing -> (0, 0)
      Just idx -> if idx < length ordered - 1 then ordered !! (idx + 1) else (0, 0)
-}

    (newevents, toremove)
      | prev == (0, 0) = 
        ( maybeToList $ circleEvent i k (snd next) points
        , [(i, j, k), (j, k, snd next)] )
      | next == (0, 0) =
        ( maybeToList $ circleEvent (fst prev) i k points
        , [(i, j, k), (fst prev, i, j)] )
      | otherwise = 
        ( catMaybes [circleEvent i k (snd next) points, circleEvent (fst prev) i k points]
        , [(i, j, k), (fst prev, i, j), (j, k, snd next)] )
  in 
    (newbreaks, newevents, toremove)

-- ** Processing events

{-|
   Process a NewPoint Event. It will result in a new set of breakpoints, a new
   edge, and potentially new events and events to be removed.
-}
processNewPoint :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => State a-> State a
processNewPoint state =
  let
    idx = V.head . snewpointevents $ state
    p = V.unsafeIndex points idx
    breaks = sbreaks state
    points = spoints state
    
    -- There is a special case for the first set of breakpoints:
    firstPair = Node Nil (sfirst state, idx) $
      Node Nil (idx, sfirst state) Nil
--    firstPair = [ Breakpoint (sfirst state) idx (fst p)
--                , Breakpoint idx (sfirst state) (fst p)]
--    firstEdge = edge (sfirst state) idx (-1, -1) (-1, -1)

    -- If this is not the first pair of breakpoints:

    -- In the following lines, centerIndex is the index of the center whose
    -- parabolic section the new breakpoints land on. leftIndex and rightIndex
    -- represent the indexes of the centers of the previous and following
    -- parabolic sections to the center one, if there are any, or Nothing.

    (inserted, (j, side)) = insertPair (fst p) idx (snd p) points breaks

    updated b = updateBreakpoint b points (snd p)
    
    (next, prev) = if j == fst side then
      (side, inOrderPredecessor (updated side) side (snd p) points breaks)
    else
      (inOrderSuccessor (updated side) side (snd p) points breaks, side)
      

{-
    -- TESTING
    ordered = fmap snd $ inorder inserted
    index = elemIndex (j, idx) ordered
    index2 = elemIndex (idx, j) ordered
    prevtest = case index of
      Nothing -> (0, 0)
      Just idx -> if idx > 0 then ordered !! (idx - 1) else (0,0)
    nexttest = case index2 of
      Nothing -> (0, 0)
      Just idx -> if idx < length ordered - 1 then ordered !! (idx + 1) else (0, 0)
-}

    leftIndex   = if prev == (0, 0) then Nothing else Just $ indexAtLeftOf  $ prev
    rightIndex  = if next == (0, 0) then Nothing else Just $ indexAtRightOf $ next
    centerIndex = j


--    newEdge = edge idx centerIndex (-1, -1) (-1, -1)

    
    -- Helper function to create a circle event where the first or last index
    -- might be Nothing.
--    circleEvent' :: Maybe Index -> Index -> Maybe Index -> [Event a]
    circleEvent' i' j k' = case (i', k') of
      (Just i, Just k) -> maybeToList $ circleEvent i j k points
      _ -> []

    -- newEvents' might be a list of length 1 or 2, but should never be an empty
    -- list, as the first pair of breakpoints is  treated separately.
    newEvents' = circleEvent' leftIndex  centerIndex (Just idx) ++
                 circleEvent' (Just idx) centerIndex rightIndex

    -- toRemove :: (Maybe Index, Index, Maybe Index)
    toRemove = (leftIndex, centerIndex, rightIndex)

    sortPair a b = (min a b, max a b)
    -- Here are all the final values, which take into account wether we are in
    -- the first pair of breakpoints or not:
    newEdges
      | null breaks = Map.singleton (sortPair (sfirst state) idx) PlaceHolder
      | otherwise   = Map.insert (sortPair idx centerIndex) PlaceHolder $ sedges state

    newCircleEvents
      | null breaks = []
      | otherwise = if any (\(CircleEvent _ _ _ y _) -> y < snd p) newEvents' then error "CircleEvent at previous y" else
        insertEvents newEvents' $
          (case toRemove of
            (Just i, j, Just k) -> removeCEvent i j k
            _ -> id)  $ scircleevents state

    newBreaks
      | null breaks = firstPair
      | otherwise   = inserted

  in
    state { sbreaks = newBreaks, sedges = newEdges, scircleevents = newCircleEvents,
      snewpointevents = V.tail (snewpointevents state), sprevd = snd p}

{- |
    Process a CircleEvent Event. It will join the converging breakpoints and
    adjusts the events and edges accordingly.
-}
processCircleEvent :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => State a -> State a
processCircleEvent state = 
  let
    (CircleEvent i j k y p) = head $ scircleevents state
    breaks = sbreaks state
    points = spoints state

    -- helper function to edit Lists:
    modifyList pos ele list = let (ls,rs) = splitAt pos list in
      ls ++ ele:tail rs

    (newBreaks, newEvents', toRemove) =
      joinBreakpoints p i j k y (sprevd state + (y - sprevd state)/2) breaks points

    newEdge = IEdge p

    uncurry3 f (a,b,c) = f a b c
    newEvents = insertEvents newEvents' $
      foldr (uncurry3 removeCEvent) (tail $ scircleevents state) toRemove
    
    sortPair a b = (min a b, max a b)

    setVert (i, j) (edges, finaledges) = case maybeFinalEdge of
      Just (IEdge p') -> (newMap, (Edge (min i j) (max i j) p' p):finaledges)
      Nothing -> (newMap, finaledges)
      where
        (maybeFinalEdge, newMap) = Map.updateLookupWithKey updateEdge (sortPair i j) edges
        updateEdge _ PlaceHolder = Just $ IEdge p
        updateEdge _ _ = Nothing

    (newEdges', newFinalEdges) = foldr setVert (sedges state, sfinaledges state) [(i, j), (j, k)]
    newEdges = Map.insert (sortPair i k) newEdge newEdges'
  in
    state { sbreaks = newBreaks, scircleevents = newEvents, sedges = newEdges, sfinaledges = newFinalEdges, sprevd = y} 

-- ** Algorithm

{- |
    Advance the sweeping line to the next Event. Just applies the corresponding
    processing function to the next event.
-}
nextEvent :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => State a -> State a
nextEvent state
  | V.null (snewpointevents state) && null (scircleevents state) = state
  | otherwise =
    if nextIsCircle then
      processCircleEvent state
    else
      processNewPoint state
  where
    nextPointY = (\idx -> snd $ V.unsafeIndex (spoints state) idx) $ V.head $ snewpointevents state
    nextCircleY = (\(CircleEvent _ _ _ y _) -> y) $ head $ scircleevents state
    nextIsCircle
      | V.null (snewpointevents state) = True
      | null (scircleevents state) = False
      | otherwise = nextCircleY <= nextPointY

{- |
    After finishing processing all events, we may end up with breakpoints that
    extend to infinity. This function trims those edges to a bounding box 10
    units bigger than the most extreme vertices.
-}

finish :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => State a -> State a
finish state
  | null (sbreaks state) = state
  | otherwise =
    let
      breaks = fmap (\x -> (updateBreakpoint x points (maxY + 20), x)) $
        inorder $ sbreaks state
      finaledges = sfinaledges state
      points = spoints state

      -- min* and max* hold the extreme values for the edges, while min*' and
      -- max*' hold those of the points. This code will figure out which way to
      -- extend the edge based on the maximum and minimum values of the points.
      -- That is to say, if for example our x value is nearest to the maximum x
      -- value of the points, then we will extend to the right (up until maxX,
      -- the maximum x value of the known edges). In the end, all vertices will
      -- be bounded to (minX, minY) (maxX, maxY) which is the original bounding
      -- box plus 20 units on each side.

      xs = (\x -> (x, x)) <$>
        concatMap (\(Edge _ _ (x, _) (x', _)) -> [x, x']) finaledges
      ys = (\x -> (x, x)) <$>
        concatMap (\(Edge _ _ (_, y) (_, y')) -> [y, y']) finaledges
      (minX, maxX) = (\(a, b) -> (a - 20, b + 20)) $
        foldl1 (\(a,x) (b,y) -> (min a b, max x y)) xs
      (minY, maxY) = (\(a, b) -> (a - 20, b + 20)) $
        foldl1 (\(a,x) (b,y) -> (min a b, max x y)) ys

      xs' = (\x -> (x, x)) <$>
        concatMap (uncurry $ flip (:) . (:[])) (V.toList points)
      ys' = (\x -> (x, x)) <$>
        concatMap (uncurry $ flip (:) . (:[])) (V.toList points)
      (minX', maxX') = (\(a, b) -> (a, b)) $
        foldl1 (\(a,x) (b,y) -> (min a b, max x y)) xs'
      (minY', maxY') = (\(a, b) -> (a, b)) $
        foldl1 (\(a,x) (b,y) -> (min a b, max x y)) ys'

      
      inRangeY b = b > minY && b < maxY
      nearest a (b, c) (d, e) = if abs (a - b) < abs (a - c)
        then d else e

      -- The guard here is to prevent trying to use the equation for a straight
      -- line in the case of a (almost) horizontal or (almost) vertical line, as
      -- the slope would be infinite. "xc" and "yc" are the "corrected" x and y
      -- value (bounded to the bounding box). We use xc if the corresponding
      -- y-value falls into rante, or yc with its corresponding x-value.

      restrict (x1,y1) (x',y')
        | abs (x1 - x') > 0.00001 && abs (y1 - y') > 0.00001 =
          if inRangeY (snd restrictX) then restrictX else restrictY
        | abs (x1 - x') <= 0.00001 =
          (x', yc)
        | otherwise =
          (xc, y')
        where
          restrictX = (xc, (xc - x1)*(y1 - y')/(x1 - x') + y1)
          restrictY = ((yc - y1)*(x1 - x')/(y1 - y') + x1, yc)
          xc = nearest x1 (maxX', minX') (maxX, minX) 
          yc = nearest y1 (maxY', minY') (maxY, minY) 

      modifyList pos ele list = let (ls,rs) = splitAt pos list in
        ls ++ ele:tail rs
      
      sortPair a b = (min a b, max a b)

      setVert (x, (i, j)) (edges, finaledges) = case maybeFinalEdge of
        Just (IEdge p') -> (newMap, (Edge (min i j) (max i j) p' (restrict p' p)):finaledges)
        Nothing -> (newMap, finaledges)
        where
          (maybeFinalEdge, newMap) = Map.updateLookupWithKey updateEdge (sortPair i j) edges
          updateEdge _ PlaceHolder = Just $ IEdge p
          updateEdge _ _ = Nothing
          p = (x, evalParabola (points `V.unsafeIndex` i) (maxY + 20) x)
    in
      state { sfinaledges = snd $ foldr setVert (sedges state, sfinaledges state) breaks }

{- |
    Create an initial state from a given set of centers.
-}
mkState :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) => [Point a] -> State a
mkState points' =
  let
    points = V.fromList points'
    sorted = sortOn (snd.snd) $
      V.foldl (\acc x -> (length acc, x):acc)  [] points
    events = V.fromList $ tail $ [0..(length sorted - 1)]
  in
    State points events [] Nil Map.empty [] (fst $ head sorted) (snd.snd $ head sorted)


-- ** Helper functions

-- | Smart constructor of Edge: it ensures that the indexes are sorted.
edge :: (Show a, Floating a, RealFrac a) => Index -> Index -> Point a -> Point a -> Edge a
edge i j = Edge (min i j) (max i j) 

-- | Given three indexes and the list of points, check if the three points at
-- the indexes form a circle, and create the corresponding CircleEvent.
circleEvent :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a)
            => Index -> Index -> Index
            -> V.Vector (Point a) -> Maybe (CircleEvent a)
circleEvent i j k points = case circle of
    Just (c@(_, y), r) -> Just $ CircleEvent i j k (y + r) c
    _ -> Nothing
  where
    circle = circleFrom3Points (points `V.unsafeIndex` i)
      (points `V.unsafeIndex` j) (points `V.unsafeIndex` k)
-- | 'evalParabola focus directrix x' evaluates the parabola defined by the
-- focus and directrix at x
evalParabola :: (Show a, Floating a, RealFrac a) => Point a -> a -> a -> a
evalParabola (fx, fy) d x = (fx*fx-2*fx*x+fy*fy-d*d+x*x)/(2*fy-2*d)

{- |
    > intersection f1 f2 d
    Find the intersection between the parabolas with focus /f1/ and /f2/ and
    directrix /d/.
-}
intersection :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) 
             => Point a -> Point a -> a -> a
intersection (f1x, f1y) (f2x, f2y) d =
  let
    dist = (f1x - f2x) * (f1x - f2x) + (f1y - f2y) * (f1y-f2y)
    sqroot = sqrt $ dist * (f1y - d) * (f2y - d)
    lastterm = f1x * (d - f2y) - f2x * d
    --x1 = (f1y*f2x - sqroot + lastterm)/(f1y - f2y)
    x = (f1y*f2x + sqroot + lastterm)/(f1y - f2y)
  in
    x
    --evalParabola (f1x, f1y) d x
    --(evalParabola (f1x, f1y) d x1, evalParabola (f1x, f1y) d x2)

-- | Returns (Just) the (center, radius) of the circle defined by three given points.
-- If the points are colinear or counter clockwise, it returns Nothing.
circleFrom3Points :: (Show a, Floating a, RealFrac a, Ord a, V.Unbox a) 
                  => Point a -> Point a -> Point a -> Maybe (Point a, a)
circleFrom3Points (x1, y1) (x2, y2) (x3,y3) =
  let
    (bax, bay) = (x2 - x1, y2 - y1)
    (cax, cay) = (x3 - x1, y3 - y1)
    ba = bax * bax + bay * bay
    ca = cax * cax + cay * cay
    denominator = 2 * (bax * cay - bay * cax)

    x = x1 + (cay * ba - bay * ca) / denominator
    y = y1 + (bax * ca - cax * ba) / denominator
    r = sqrt $ (x-x1) * (x-x1) + (y-y1) * (y-y1)
  in
    if denominator <= 0 then
      Nothing -- colinear points or counter clockwise
    else
      Just ((x, y), r)

{-
-- TESTING
ps = [(4.875336608745524,0.150657445690765),(-11.216506035212621,11.490726842927694),(-17.913707206936614,11.672517034976156),(15.314369189316707,16.33601558000406),(0.38035112816248784,17.775820279123977),(-11.876298872777857,18.270923221004796),(-5.012380039840515,25.160054714017036),(-9.053182555292008,30.181962786460275),(16.44086477504638,32.48880821636015)] :: [(Double, Double)]
ini = mkState ps
steps = iterate nextEvent ini
bs = fmap sbreaks steps
bs' = fmap inorder bs
bs'' d = fmap (fmap (\(_,b) -> (updateBreakpoint b (V.fromList ps) d,b))) bs'
-}
