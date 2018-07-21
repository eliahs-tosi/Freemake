module GameWorld exposing (Node, State, FromPlayerInput, init, updateForPlayerInput, view)

import Visuals
import Point2d exposing (Point2d)
import Vector2d exposing (Vector2d)
import Direction2d exposing (Direction2d)
import Dict
import Set
import Html
import Pointer
import Svg
import Svg.Attributes as SA


type Location = OnNode NodeId

type alias NodeId = Int

type alias Node =
    {   visualLocation : Point2d
    }

type alias State =
    {   playerLocation : Location
    ,   nodes : Dict.Dict NodeId Node
    ,   edges : Set.Set EdgeDirection
    }

type alias EdgeDirection = (NodeId, NodeId)

type FromPlayerInput = MoveToNode NodeId

type alias EdgeDerivedProperties =
    {   origLocation : Point2d
    ,   destLocation : Point2d
    }


initNodes : Dict.Dict NodeId Node
initNodes =
    [   { visualLocation = Point2d.fromCoordinates (100, 100) }
    ,   { visualLocation = Point2d.fromCoordinates (200, 90) }
    ,   { visualLocation = Point2d.fromCoordinates (210, 200) }
    ,   { visualLocation = Point2d.fromCoordinates (280, 160) }
    ,   { visualLocation = Point2d.fromCoordinates (95, 200) }
    ]
    |> List.indexedMap (\i node -> (i, node))
    |> Dict.fromList

edgesToConnectAllNodes : Dict.Dict NodeId Node -> Set.Set EdgeDirection
edgesToConnectAllNodes nodes =
    nodes |> Dict.keys |> List.concatMap (\orig -> nodes |> Dict.keys |> List.map (\dest -> (orig, dest)))
    |> List.filter (\(orig, dest) -> orig /= dest)
    |> Set.fromList

shouldKeepAutogeneratedEdge : EdgeDerivedProperties -> Bool
shouldKeepAutogeneratedEdge properties =
    Point2d.distanceFrom properties.origLocation properties.destLocation < 130

initEdges : Dict.Dict NodeId Node -> Set.Set EdgeDirection
initEdges nodes =
    nodes |> edgesToConnectAllNodes
    |> Set.filter ((getEdgeDerivedProperties nodes) >> (Maybe.map shouldKeepAutogeneratedEdge) >> Maybe.withDefault False)

init : State
init =
    {   playerLocation = OnNode (initNodes |> Dict.keys |> List.head |> Maybe.withDefault 0)
    ,   nodes = initNodes
    ,   edges = initEdges initNodes
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
        edgesView = state.edges |> Set.toList |> List.map (viewEdge state) |> Svg.g []
    in
        [ edgesView, nodesView ] |> Svg.g []

edgeViewWidth : Float
edgeViewWidth = 4

nodeViewRadius : Float
nodeViewRadius = 10

viewEdge : State -> EdgeDirection -> Svg.Svg event
viewEdge worldState edge =
    case getEdgeDerivedProperties worldState.nodes edge of
    Just edgeDerivedProperties ->
        case Direction2d.from edgeDerivedProperties.origLocation edgeDerivedProperties.destLocation of
        Nothing -> Html.text ""
        Just direction ->
            let
                edgeVisualOffset = direction |> Direction2d.rotateBy (pi / 2) |> Vector2d.withLength edgeViewWidth

                visualEndpoints =
                    [ edgeDerivedProperties.origLocation, edgeDerivedProperties.destLocation ]
                    |> List.map (Point2d.translateBy edgeVisualOffset)
            in
                Visuals.svgPolylineWithStroke ("lightgrey", edgeViewWidth) visualEndpoints
    Nothing -> Html.text ""

viewNode : State -> (NodeId, Node) -> Svg.Svg FromPlayerInput
viewNode worldState (nodeId, node) =
    let
        isPlayerLocatedHere = worldState.playerLocation == (OnNode nodeId)

        nodeBaseView =
            Svg.circle [ SA.r (nodeViewRadius |> toString), SA.fill "grey" ] []

        playerView =
            if isPlayerLocatedHere
            then Svg.circle [ SA.r "4", SA.fill "black" ] []
            else Html.text ""

        transformAttribute = SA.transform (node.visualLocation |> Point2d.coordinates |> Visuals.svgTransformTranslate)

        inputAttribute = Pointer.onDown (always (MoveToNode nodeId))
    in
        [ nodeBaseView, playerView ]
        |> Svg.g [ inputAttribute, transformAttribute ]

getEdgeDerivedProperties : Dict.Dict NodeId Node -> EdgeDirection -> Maybe EdgeDerivedProperties
getEdgeDerivedProperties nodes (origNodeId, destNodeId) =
    let
        visualLocationFromNodeId nodeId = nodes |> Dict.get nodeId |> Maybe.map .visualLocation
    in
        case (visualLocationFromNodeId origNodeId, visualLocationFromNodeId destNodeId) of
        (Just origLocation, Just destLocation) -> Just { origLocation = origLocation, destLocation = destLocation }
        _ -> Nothing
