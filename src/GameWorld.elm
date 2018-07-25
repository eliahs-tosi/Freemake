module GameWorld exposing (Node, State, Location(..), FromPlayerInput, init, updateForPlayerInput, view)

import Visuals
import Point2d exposing (Point2d)
import Vector2d exposing (Vector2d)
import Direction2d exposing (Direction2d)
import LineSegment2d exposing (LineSegment2d)
import Dict
import Set
import Html
import Html.Attributes as HA
import Pointer
import Svg
import Svg.Attributes as SA
import ParseSvg
import MapRawXml
import Parser
import XmlParser
import Maybe.Extra
import Tuple2


type Location = OnNode NodeId

type alias NodeId = Int

type alias Node =
    {   visualLocation : Point2d
    }

type alias State =
    {   playerLocation : Location
    ,   nodes : Dict.Dict NodeId Node
    ,   edges : Set.Set EdgeDirection
    ,   visuals : GameWorldVisuals
    }

type alias EdgeDirection = (NodeId, NodeId)

type FromPlayerInput = MoveToNode NodeId

type alias EdgeDerivedProperties =
    {   lineSegmentBetweenNodes : LineSegment2d
    }

type alias GameWorldVisuals =
    {   polygons : List (List Point2d, String)
    }


initNodes : Dict.Dict NodeId Node
initNodes =
    initMap |> Result.map Tuple.first |> Result.withDefault []
    |> List.indexedMap (\i node -> (i, node))
    |> Dict.fromList

edgesToConnectAllNodes : Dict.Dict NodeId Node -> Set.Set EdgeDirection
edgesToConnectAllNodes nodes =
    nodes |> Dict.keys |> List.concatMap (\orig -> nodes |> Dict.keys |> List.map (\dest -> (orig, dest)))
    |> List.filter (\(orig, dest) -> orig /= dest)
    |> Set.fromList

shouldKeepAutogeneratedEdge : EdgeDerivedProperties -> Bool
shouldKeepAutogeneratedEdge properties =
    (properties.lineSegmentBetweenNodes |> LineSegment2d.length) < 160

initEdges : Dict.Dict NodeId Node -> Set.Set EdgeDirection
initEdges nodes =
    nodes |> edgesToConnectAllNodes
    |> Set.filter ((getEdgeDerivedProperties nodes) >> (Maybe.map shouldKeepAutogeneratedEdge) >> Maybe.withDefault False)
    |> removeLongerIntersectingEdges nodes

init : State
init =
    {   playerLocation = OnNode (initNodes |> Dict.keys |> List.head |> Maybe.withDefault 0)
    ,   nodes = initNodes
    ,   edges = initEdges initNodes
    ,   visuals = initMap |> Result.map Tuple.second |> Result.withDefault { polygons = [] }
    }

updateForPlayerInput : FromPlayerInput -> State -> State
updateForPlayerInput playerInput stateBefore =
    case playerInput of
    MoveToNode destNodeId ->
        case stateBefore.playerLocation of
        OnNode beforeLocationNodeId ->
            if stateBefore.edges |> Set.member (beforeLocationNodeId, destNodeId)
            then { stateBefore | playerLocation = OnNode destNodeId }
            else stateBefore

view : State -> Svg.Svg FromPlayerInput
view state =
    let
        nodesView = state.nodes |> Dict.toList |> List.map (viewNode state) |> Svg.g []
        edgesView = state.edges |> Set.toList |> List.map (viewEdge state) |> Svg.g [ SA.opacity "0.5" ]
    in
        [   state.visuals |> viewVisuals
        ,   edgesView
        ,   nodesView
        ] |> Svg.g []

edgeViewWidth : Float
edgeViewWidth = 2

nodeViewRadius : Float
nodeViewRadius = 6

playerLocationIndicatorRadiusBase : Float
playerLocationIndicatorRadiusBase = nodeViewRadius * 0.4

viewEdge : State -> EdgeDirection -> Svg.Svg event
viewEdge worldState edge =
    case getEdgeDerivedProperties worldState.nodes edge of
    Just edgeDerivedProperties ->
        case edgeDerivedProperties.lineSegmentBetweenNodes |> edgeVisualLineSegmentFromLineSegmentBetweenNodes of
        Nothing -> Html.text ""
        Just visualLineSegment ->
            Visuals.svgLineSegmentWithStroke ("lightgrey", edgeViewWidth) visualLineSegment
    Nothing -> Html.text ""

edgeVisualLineSegmentFromLineSegmentBetweenNodes : LineSegment2d -> Maybe LineSegment2d
edgeVisualLineSegmentFromLineSegmentBetweenNodes lineSegmentBetweenNodes =
    case lineSegmentBetweenNodes |> LineSegment2d.direction of
    Nothing -> Nothing
    Just direction ->
        let
            edgeVisualOffset = direction |> Direction2d.rotateBy (pi / 2) |> Vector2d.withLength edgeViewWidth

            visualLength = (lineSegmentBetweenNodes |> LineSegment2d.length) - (nodeViewRadius * 3)

            scaleFactor = visualLength / (lineSegmentBetweenNodes |> LineSegment2d.length)
        in
            lineSegmentBetweenNodes
            |> LineSegment2d.scaleAbout (lineSegmentBetweenNodes |> LineSegment2d.midpoint) scaleFactor
            |> LineSegment2d.mapEndpoints (Point2d.translateBy edgeVisualOffset)
            |> Just

viewNode : State -> (NodeId, Node) -> Svg.Svg FromPlayerInput
viewNode worldState (nodeId, node) =
    let
        isPlayerLocatedHere = worldState.playerLocation == (OnNode nodeId)

        pointerDownEvent = MoveToNode nodeId

        worldAfterPointerDownEvent = worldState |> updateForPlayerInput pointerDownEvent

        indicateEffectForInput = worldAfterPointerDownEvent.playerLocation /= worldState.playerLocation

        canPlayerGetHereDirectly = worldAfterPointerDownEvent.playerLocation == (OnNode nodeId)

        nodeBaseView =
            svgCircleFromRadiusAndFillAndStroke (nodeViewRadius, "grey") Nothing

        playerView =
            if isPlayerLocatedHere
            then svgCircleFromRadiusAndFillAndStroke (playerLocationIndicatorRadiusBase, "black") Nothing
            else if canPlayerGetHereDirectly
            then playerCanGetHereDirectlyIndication
            else Html.text ""

        opacity =
            if isPlayerLocatedHere then 1 else if canPlayerGetHereDirectly then 0.7 else 0.4

        transformAttribute = SA.transform (node.visualLocation |> Point2d.coordinates |> Visuals.svgTransformTranslate)

        inputAttributes =
            [ Pointer.onDown (always pointerDownEvent) ] ++
            (if indicateEffectForInput
            then [ HA.style [("cursor","pointer")] ]
            else [])

        additionalInputArea =
            svgCircleFromRadiusAndFillAndStroke (nodeViewRadius * 4, "transparent") Nothing
    in
        [ additionalInputArea, nodeBaseView, playerView ]
        |> Svg.g (inputAttributes ++ [ transformAttribute, SA.opacity (opacity |> toString) ])

viewVisuals : GameWorldVisuals -> Svg.Svg event
viewVisuals visuals =
    visuals.polygons
    |> List.map (Tuple.mapFirst (Visuals.svgPathDataFromPolylineListPoint Visuals.MoveTo))
    |> List.map (\(pathData, color) -> Svg.path [ SA.d pathData, SA.fill color ] [])
    |> Svg.g []

getEdgeDerivedProperties : Dict.Dict NodeId Node -> EdgeDirection -> Maybe EdgeDerivedProperties
getEdgeDerivedProperties nodes (origNodeId, destNodeId) =
    let
        visualLocationFromNodeId nodeId = nodes |> Dict.get nodeId |> Maybe.map .visualLocation
    in
        case (visualLocationFromNodeId origNodeId, visualLocationFromNodeId destNodeId) of
        (Just origLocation, Just destLocation) ->
            Just { lineSegmentBetweenNodes = LineSegment2d.fromEndpoints (origLocation, destLocation) }
        _ -> Nothing

playerCanGetHereDirectlyIndication : Svg.Svg event
playerCanGetHereDirectlyIndication =
    svgCircleFromRadiusAndFillAndStroke
        (playerLocationIndicatorRadiusBase, "none")
        (Just (playerLocationIndicatorRadiusBase / 4, "black"))

svgCircleFromRadiusAndFillAndStroke : (Float, String) -> Maybe (Float, String) -> Svg.Svg event
svgCircleFromRadiusAndFillAndStroke (radius, fill) maybeStrokeWidthAndColor =
    let
        strokeAttributes =
            maybeStrokeWidthAndColor
            |> Maybe.map (\(strokeWidth, strokeColor) -> [ SA.stroke strokeColor, SA.strokeWidth (strokeWidth |> toString) ])
            |> Maybe.withDefault []
    in
        Svg.circle ([SA.r (radius |> toString), SA.fill fill] ++ strokeAttributes) []

initMap : Result Parser.Error (List Node, GameWorldVisuals)
initMap =
    MapRawXml.xml |> XmlParser.parse |> Result.map parseMapXml

parseMapXml : XmlParser.Xml -> (List Node, GameWorldVisuals)
parseMapXml mapXml =
    let
        allXmlElements =
            mapXml.root |> ParseSvg.xmlListSelfAndDescendantsNodesDepthFirst |> List.filterMap ParseSvg.xmlNodeAsElement

        accessNodes : List Node
        accessNodes =
            allXmlElements |> List.filter ParseSvg.xmlElementIsCircle
            |> List.filterMap ParseSvg.getCircleLocation
            |> List.map (\location -> { visualLocation = location })

        parsePathsResults =
            allXmlElements
            |> List.filter (\element -> element.tag == "path")
            |> List.map ParseSvg.getPolygonPointsAndColorFromXmlElement

        polygons =
            parsePathsResults
            |> List.map Result.toMaybe
            |> Maybe.Extra.combine
            |> Maybe.withDefault []
    in
        (accessNodes, { polygons = polygons })

removeLongerIntersectingEdges : Dict.Dict NodeId Node -> Set.Set EdgeDirection -> Set.Set EdgeDirection
removeLongerIntersectingEdges nodes edges =
  let
    lineSegmentFromEdge edge =
        getEdgeDerivedProperties nodes edge |> Maybe.map .lineSegmentBetweenNodes

    shortenLineSegment origLineSegment =
        origLineSegment |> LineSegment2d.scaleAbout (origLineSegment |> LineSegment2d.midpoint) 0.99

    areEdgesIntersecting edgeA edgeB =
        if edgeA == edgeB || (edgeA |> Tuple2.swap) == edgeB
        then False
        else
            case (edgeA, edgeB) |> Tuple2.mapBoth (lineSegmentFromEdge >> Maybe.map shortenLineSegment) of
            (Just edgeALineSegment, Just edgeBLineSegment) ->
                (LineSegment2d.intersectionPoint edgeALineSegment edgeBLineSegment) /= Nothing
            _ -> False

    dictPriorityFromEdgeDirection : Dict.Dict EdgeDirection Int
    dictPriorityFromEdgeDirection =
      edges |> Set.toList
      |> List.sortBy (lineSegmentFromEdge >> Maybe.map LineSegment2d.length >> (Maybe.withDefault 9999999))
      |> List.indexedMap (\i edgeDirection -> (edgeDirection, -i))
      |> Dict.fromList

    priorityFromEdgeDirection = (dictPriorityFromEdgeDirection |> (Dict.get |> flip)) >> (Maybe.withDefault -1)
  in
    edges
    |> Set.filter (\edgeDirection ->
        let
            edgePrio = priorityFromEdgeDirection edgeDirection

            intersectingEdges =
                edges
                |> Set.filter (\otherEdgeDirection -> areEdgesIntersecting edgeDirection otherEdgeDirection)
                |> Set.toList

            intersectingEdgesPriorities =
                intersectingEdges |> List.map priorityFromEdgeDirection
        in
            intersectingEdgesPriorities
            |> List.any (\intersectingPrio -> edgePrio <= intersectingPrio)
            |> not)
