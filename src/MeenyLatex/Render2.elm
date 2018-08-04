module MeenyLatex.Render2
    exposing
        ( makeTableOfContents
        , render
        , renderLatexList
        , renderString
        )

{-| This module is for quickly preparing latex for export.


# API

@docs makeTableOfContents, render, renderLatexList, renderString

-}

import Dict
import Html exposing (Html)
import Html.Attributes
import Json.Encode


-- import List.Extra

import MeenyLatex.Render
import MeenyLatex.Configuration as Configuration
import MeenyLatex.ErrorMessages as ErrorMessages
import MeenyLatex.Image as Image exposing (..)
import MeenyLatex.JoinStrings as JoinStrings
import MeenyLatex.LatexState
    exposing
        ( LatexState
        , TocEntry
        , emptyLatexState
        , getCounter
        , getCrossReference
        , getDictionaryItem
        )
import MeenyLatex.Parser exposing (LatexExpression(..), defaultLatexList, latexList)
import MeenyLatex.Utility as Utility
import Parser exposing(DeadEnd, Problem(..))
import Regex
import String
import Html.Attributes as HA
import MeenyLatex.ListMachine as ListMachine  
import MeenyLatex.ParserTools as PT


-- |> \str -> "\n<p>" ++ str ++ "</p>\n"
{- FUNCTIONS FOR TESTING THINGS -}


getElement : Int -> List LatexExpression -> LatexExpression
getElement k list =
    Utility.getAt k list |> Maybe.withDefault (LXString "xxx")


parseString parser str =
    Parser.run parser str



-- renderString latexList latexState text


{-| Parse a string, then render it.
-}
renderString : LatexState -> String -> Html msg
renderString latexState str =
    str
        |> MeenyLatex.Parser.parse
        |> List.map (render latexState)
        |> Html.div []


postProcess : String -> String
postProcess str =
    str
        |> String.replace "---" "&mdash;"
        |> String.replace "--" "&ndash;"
        |> String.replace "\\&" "&#38"



{- TYPES AND DEFAULT VALJUES -}


extractList : LatexExpression -> List LatexExpression
extractList latexExpression =
    case latexExpression of
        LatexList a ->
            a

        _ ->
            []


{-| THE MAIN RENDERING FUNCTION
-}
mathText : String -> Html msg
mathText content =
    Html.node "math-text"
        [ Html.Attributes.property "content" (Json.Encode.string content) ]
        []


{-| The main rendering funcction. Compute an Html msg value
from the current LatexState and a LatexExpresssion.
-}
render : LatexState -> LatexExpression -> Html msg
render latexState latexExpression =
    case latexExpression of
        Comment str ->
            Html.p [] [ Html.text <| "" ]

        Macro name optArgs args ->
            renderMacro latexState name optArgs args

        SMacro name optArgs args le ->
            renderSMacro latexState name optArgs args le

        Item level latexExpr ->
            renderItem latexState level latexExpr

        InlineMath str ->
            Html.span [] [ oneSpace, inlineMathText str ]

        DisplayMath str ->
            displayMathText str

        Environment name args body ->
            renderEnvironment latexState name args body

        LatexList latexList ->
            renderLatexList latexState latexList

        LXString str ->
            Html.span [] [ Html.text str ]

        LXError error ->
            Html.p [] [ Html.text <| (String.join "\n---\n\n" (List.map errorReport error))]


errorReport : DeadEnd -> String 
errorReport deadEnd = 
  "Error at row " ++ String.fromInt deadEnd.row ++ ", column " ++ String.fromInt deadEnd.col ++ "\n: " ++ (reportProblem deadEnd.problem)


reportProblem : Problem -> String 
reportProblem problem = 
  case problem of 
    Expecting str -> "Expecting string: " ++ str 
    ExpectingInt -> "Expecting int"
    ExpectingSymbol str -> "Expecting symbol: " ++ str
    ExpectingKeyword str -> "Expecting keyword: " ++ str
    ExpectingEnd -> "Expecting end"
    UnexpectedChar -> "Unexpected char"
    BadRepeat -> "Bad repeat"
    _ -> "Other problem"


 

inlineMathText : String -> Html msg
inlineMathText str =
    mathText <| "$ " ++ String.trim str ++ " $"


displayMathText : String -> Html msg
displayMathText str =
    mathText <| "$$\n" ++ String.trim str ++ "\n$$"




{- PROCESS SPACES BETWEEN ELEMENTS  V2 -}

addSpace : ListMachine.InternalState LatexExpression -> LatexExpression 
addSpace internalState = 
  let
    a = internalState.before  |> Maybe.withDefault (LXString "") 
    b = internalState.current |> Maybe.withDefault (LXString "")  
    c = internalState.after   |> Maybe.withDefault (LXString "")  
  in  
    case (a,b,c) of
        (Macro _ _ _,  LXString str, _) ->
            if List.member (firstChar str) [ ".", ",", "?", "!", ";", ":" ] then
                (LXString str)
            else
                (LXString (" " ++ str))

        (InlineMath _,  LXString str, _) ->
            if List.member (firstChar str) [ ".", ",", "?", "!", ";", ":" ] then
                (LXString str)
            else
                (LXString (" " ++ str))

        (_, LXString str, _) ->
            if List.member (lastChar str) [ ")", ".", ",", "?", "!", ";", ":" ] then 
                (LXString (str ++ " "))
            else 
                (LXString str)
         
        (_, _, _) -> b


lastChar =
    String.right 1


firstChar =
    String.left 1



{-| Like `render`, but renders a list of LatexExpressions
to Html mgs
-}
renderLatexList : LatexState -> List LatexExpression -> Html msg
renderLatexList latexState latexList =
    latexList
        |> ListMachine.runMachine addSpace
        |> (\list -> Html.span [ HA.style "margin-bottom" "10px" ] (List.map (render latexState) list))



{- RENDER MACRO -}


renderMacro : LatexState -> String -> List LatexExpression -> List LatexExpression -> Html msg
renderMacro latexState name optArgs args =
    (macroRenderer name) latexState optArgs args


renderArg : Int -> LatexState -> List LatexExpression -> Html msg
renderArg k latexState args =
    render latexState (getElement k args)


macroRenderer : String -> (LatexState -> List LatexExpression -> List LatexExpression -> Html msg)
macroRenderer name latexState optArgs args =
    case Dict.get name renderMacroDict of
        Just f ->
            f latexState optArgs args

        Nothing ->
            reproduceMacro name latexState optArgs args


reproduceMacro : String -> LatexState -> List LatexExpression -> List LatexExpression -> Html msg
reproduceMacro name latexState optArgs args =
    let
        renderedArgs =
            renderArgList latexState args |> List.map enclose
    in
        Html.span []
            ([ Html.text <| "\\" ++ name ] ++ renderedArgs)


boost : (x -> z -> output) -> (x -> y -> z -> output)
boost f =
    \x y z -> f x z


renderMacroDict : Dict.Dict String (LatexState -> List LatexExpression -> List LatexExpression -> Html.Html msg)
renderMacroDict =
    Dict.fromList
        [ ( "bigskip", \x y z -> renderBigSkip x z )
        , ( "medskip", \x y z -> renderMedSkip x z )
        , ( "smallskip", \x y z -> renderSmallSkip x z )
        , ( "bozo", boost renderBozo )
        , ( "cite", \x y z -> renderCite x z )
        , ( "code", \x y z -> renderCode x z )
        , ( "ellie", \x y z -> renderEllie x z )
        , ( "emph", \x y z -> renderItalic x z )
        , ( "eqref", \x y z -> renderEqRef x z )
        , ( "href", \x y z -> renderHRef x z )
        , ( "image", \x y z -> renderImage x z )
        , ( "imageref", \x y z -> renderImageRef x z )
        , ( "index", \x y z -> renderIndex x z )
        , ( "italic", \x y z -> renderItalic x z )
        , ( "label", \x y z -> renderLabel x z )
        , ( "maketitle", \x y z -> renderTitle x z )
        , ( "mdash", \x y z -> renderMdash x z )
        , ( "ndash", \x y z -> renderNdash x z )
        , ( "underscore", \x y z -> renderUnderscore x z )
        , ( "backslash", \x y z -> renderBackslash x z )
        , ( "texarg", \x y z -> renderTexArg x z )
        , ( "newcommand", \x y z -> renderNewCommand x z )
        , ( "ref", \x y z -> renderRef x z )
        , ( "medskip", \x y z -> renderMedSkip x z )
        , ( "smallskip", \x y z -> renderSmallSkip x z )
        , ( "section", \x y z -> renderSection x z )
        , ( "section*", \x y z -> renderSectionStar x z )
        , ( "subsection", \x y z -> renderSubsection x z )
        , ( "subsection*", \x y z -> renderSubsectionStar x z )
        , ( "subsubsection", \x y z -> renderSubSubsection x z )
        , ( "subsubsection*", \x y z -> renderSubSubsectionStar x z )
        , ( "setcounter", \x y z -> renderSetCounter x z )
        , ( "subheading", \x y z -> renderSubheading x z )
        , ( "tableofcontents", \x y z -> renderTableOfContents x z )
        , ( "innertableofcontents", \x y z -> renderInnerTableOfContents x z )
        , ( "term", \x y z -> renderTerm x z )
        , ( "xlink", \x y z -> renderXLink x z )
        , ( "xlinkPublic", \x y z -> renderXLinkPublic x z )
        , ( "documentTitle", \x y z -> renderDocumentTitle x z )
        , ( "title", \x y z -> renderTitle x z )
        , ( "author", \x y z -> renderAuthor x z )
        , ( "date", \x y z -> renderDate x z )
        , ( "revision", \x y z -> renderRevision x z )
        , ( "email", \x y z -> renderEmail x z )
        , ( "setdocid", \x y z -> renderSetDocId x z )
        , ( "setclient", \x y z -> renderSetClient x z )
        , ( "strong", \x y z -> renderStrong x z )
        ]


renderArgList : LatexState -> List LatexExpression -> List (Html msg)
renderArgList latexState args =
    args |> List.map (render latexState)


enclose : Html msg -> Html msg
enclose msg =
    Html.span [] [ Html.text "{", msg, Html.text "}" ]


oneSpace : Html msg
oneSpace =
    Html.text " "



{- RENDER INDIVIDUAL MACROS -}


renderBozo : LatexState -> List LatexExpression -> Html msg
renderBozo latexState args =
    Html.span []
        [ Html.text <| "\\bozo"
        , enclose <| renderArg 0 latexState args
        , enclose <| renderArg 1 latexState args
        ]


renderItalic : LatexState -> List LatexExpression -> Html msg
renderItalic latexState args =
    Html.i [] [ Html.text " ", renderArg 0 latexState args ]


renderStrong : LatexState -> List LatexExpression -> Html msg
renderStrong latexState args =
    Html.strong [] [ oneSpace, renderArg 0 latexState args ]


renderBigSkip : LatexState -> List LatexExpression -> Html msg
renderBigSkip latexState args =
    Html.div [] [ Html.br [] [] ]


renderMedSkip : LatexState -> List LatexExpression -> Html msg
renderMedSkip latexState args =
    Html.div [] [ Html.br [] [] ]


renderSmallSkip : LatexState -> List LatexExpression -> Html msg
renderSmallSkip latexState args =
    Html.div [] [ Html.br [] [] ]


renderCite : LatexState -> List LatexExpression -> Html msg
renderCite latexState args =
    let
        label_ =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            getDictionaryItem ("bibitem:" ++ label_) latexState

        label =
            if ref /= "" then
                ref
            else
                label_
    in
        Html.span []
            [ Html.span [] [ Html.text "[" ]
            , Html.a [ Html.Attributes.href ("#bibitem:" ++ label) ] [ Html.text label ]
            , Html.span [] [ Html.text "]" ]
            ]


renderCode : LatexState -> List LatexExpression -> Html msg
renderCode latexState args =
    let
        arg =
            renderArg 0 latexState args
    in
        Html.code [] [ oneSpace, arg ]


renderEllie : LatexState -> List LatexExpression -> Html msg
renderEllie latexState args =
    let
        id =
            MeenyLatex.Render.renderArg 0 latexState args

        url =
            ("https://ellie-app.com/embed/" ++ id)

        title_ =
            MeenyLatex.Render.renderArg 1 latexState args

        title =
            if title_ == "xxx" then
                "Link to Ellie"
            else
                title_
    in
        Html.iframe [ Html.Attributes.src url, Html.Attributes.width 500, Html.Attributes.height 600 ] [ Html.text title ]


renderEqRef : LatexState -> List LatexExpression -> Html msg
renderEqRef latexState args =
    let
        key =
            MeenyLatex.Render.renderArg 0 emptyLatexState args

        ref =
            getCrossReference key latexState
    in
        Html.i [] [ Html.text "(", Html.text ref, Html.text ")" ]


renderHRef : LatexState -> List LatexExpression -> Html msg
renderHRef latexState args =
    let
        url =
            MeenyLatex.Render.renderArg 0 emptyLatexState args

        label =
            MeenyLatex.Render.renderArg 1 emptyLatexState args
    in
        Html.a [ Html.Attributes.href url ] [ Html.text label ]


renderImage : LatexState -> List LatexExpression -> Html msg
renderImage latexState args =
    let
        url =
            MeenyLatex.Render.renderArg 0 latexState args

        label =
            MeenyLatex.Render.renderArg 1 latexState args

        attributeString =
            MeenyLatex.Render.renderArg 2 latexState args

        imageAttrs =
            parseImageAttributes attributeString

        width = (String.fromInt imageAttrs.width) ++ "px"
    in
        if imageAttrs.float == "left" then
            Html.div [HA.style "float" "left"] [
                Html.img [ HA.src url, HA.alt label, HA.style "width" width, HA.style "margin-right" "12px"] [ ]
                , Html.br [] []
                , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] [Html.text label]
            ]
        else if imageAttrs.float == "right" then
             Html.div [HA.style "float" "right"] [
                Html.img [ HA.src url, HA.alt label, HA.style "width" width, HA.style "margin-left" "12px"] [ ]
                , Html.br [] []
                , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] [Html.text label]
            ]
        else if imageAttrs.align == "center" then
              Html.div [HA.style "margin-left" "auto", HA.style "margin-right" "auto", HA.style "width" width] [
                Html.img [ HA.src url, HA.alt label, HA.style "width" width] [ ]
                , Html.br [] []
                , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] [Html.text label]
            ]
        else
            Html.div [HA.style "margin-left" "auto", HA.style "margin-right" "auto", HA.style "width" width] [
                Html.img [ HA.src url, HA.alt label, HA.style "width" width] [ ]
                , Html.br [] []
                , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] [Html.text label]
            ]


renderImageRef : LatexState -> List LatexExpression -> Html msg
renderImageRef latexState args =
    let
        url =
            MeenyLatex.Render.renderArg 0 latexState args

        imageUrl =
            MeenyLatex.Render.renderArg 1 latexState args

        attributeString =
            MeenyLatex.Render.renderArg 2 latexState args

        imageAttrs =
            parseImageAttributes attributeString

        width = (String.fromInt imageAttrs.width) ++ "px"

        theImage =
            if imageAttrs.float == "left" then
                Html.div [HA.style "float" "left"] [
                        Html.img [ HA.src imageUrl, HA.alt "image link", HA.style "width" width, HA.style "margin-right" "12px"] [ ]
                        , Html.br [] []
                        , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] []
                    ]
            else if imageAttrs.float == "right" then
                Html.div [HA.style "float" "right"] [
                    Html.img [ HA.src imageUrl, HA.alt "image link", HA.style "width" width, HA.style "margin-left" "12px"] [ ]
                    , Html.br [] []
                    , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] []
                ]
            else if imageAttrs.align == "center" then
                Html.div [HA.style "margin-left" "auto", HA.style "margin-right" "auto", HA.style "width" width] [
                    Html.img [ HA.src imageUrl, HA.alt "image link", HA.style "width" width] [ ]
                    , Html.br [] []
                    , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] []
                ]
            else
                Html.div [HA.style "margin-left" "auto", HA.style "margin-right" "auto", HA.style "width" width] [
                    Html.img [ HA.src imageUrl, HA.alt "image link", HA.style "width" width] [ ]
                    , Html.br [] []
                    , Html.div [ HA.style "width" width, HA.style "text-align" "center", HA.style "display" "block"] []
                ]
    in
        Html.a [ Html.Attributes.href url ] [ theImage ]


renderIndex : LatexState -> List LatexExpression -> Html msg
renderIndex x z =
    Html.span [] []


renderLabel : LatexState -> List LatexExpression -> Html msg
renderLabel x z =
    Html.span [] []



{- RENDER TABLE CONTENTS -}


renderTableOfContents : LatexState -> List LatexExpression -> Html msg
renderTableOfContents latexState list =
    let
        innerPart =
            makeTableOfContents latexState
    in
        Html.div []
            [ Html.h3 [] [ Html.text "Table of Contents" ]
            , Html.ul [] innerPart
            ]

renderInnerTableOfContents : LatexState -> List LatexExpression -> Html msg
renderInnerTableOfContents latexState args =
    let
        prefix =  getElement 0 args 
                    |> PT.valueOfLatexList 
                    |> List.map PT.valueOfLXString 
                    |> List.head
                    |> Maybe.withDefault ""


        innerPart =
            makeInnerTableOfContents prefix latexState
    in
        Html.div []
            [ Html.h3 [] [ Html.text "Table of Contents" ]
            , Html.ul [] innerPart
            ]


{-| Build a table of contents from the
current LatexState; use only level 1 items
-}
makeTableOfContents : LatexState -> List (Html msg)
makeTableOfContents latexState =
  let 
    toc = List.filter (\item -> item.level == 1) latexState.tableOfContents
  in
    List.foldl (\tocItem acc -> acc ++ [ (makeTocItem "") tocItem ]) [] (List.indexedMap Tuple.pair toc)



{-| Build a table of contents from the
current LatexState; use only level 2 items
-}
makeInnerTableOfContents : String -> LatexState -> List (Html msg)
makeInnerTableOfContents prefix latexState =
  let 
    toc = List.filter (\item -> item.level == 2) latexState.tableOfContents
  in
    List.foldl (\tocItem acc -> acc ++ [ (makeTocItem prefix) tocItem ]) [] (List.indexedMap Tuple.pair toc)

makeTocItem : String -> ( Int, TocEntry ) -> Html msg
makeTocItem prefix tocItem =
    let
        i =
            Tuple.first tocItem

        ti =
            Tuple.second tocItem

        number = prefix ++ (String.fromInt (i+1)) ++ ". "

        classProperty =
            "class=\"sectionLevel" ++ String.fromInt ti.level ++ "\""


        id =
            makeId (sectionPrefix ti.level) ti.name

        href =
            "#" ++ id
    in
         Html.p [
                      Html.Attributes.style "font-size" "14px"
                     ,  Html.Attributes.style "padding-bottom" "0px"
                     , Html.Attributes.style "margin-bottom" "0px"
                     ,  Html.Attributes.style "padding-top" "0px"
                     , Html.Attributes.style "margin-top" "0px"
                      , Html.Attributes.style "line-height" "20px"
                ] [ 
                      Html.text number
                    , Html.a [ Html.Attributes.href href ] [ Html.text ti.name ] 
                ]


makeId : String -> String -> String
makeId prefix name =
    String.join "_" [ "", prefix, compress "_" name ]


compress : String -> String -> String
compress replaceBlank str =
    str
        |> String.toLower
        |> String.replace " " replaceBlank
        |> userReplace "[,;.!?&_]" (\_ -> "")


userReplace : String -> (Regex.Match -> String) -> String -> String
userReplace userRegex replacer string =
    case Regex.fromString userRegex of
        Nothing ->
            string

        Just regex ->
            Regex.replace regex replacer string


sectionPrefix : Int -> String
sectionPrefix level =
    case level of
        1 ->
            "section"

        2 ->
            "subsection"

        3 ->
            "subsubsection"

        _ ->
            "asection"



{- END TABLE OF CONTENTS -}


renderMdash : LatexState -> List LatexExpression -> Html msg
renderMdash latexState args =
    Html.span [] [ Html.text "— " ]  


renderNdash : LatexState -> List LatexExpression -> Html msg
renderNdash latexState args =
    Html.span [] [ Html.text "– " ]


renderUnderscore : LatexState -> List LatexExpression -> Html msg
renderUnderscore latexState args =
    Html.span [] [ Html.text "_" ]   

renderBackslash : LatexState -> List LatexExpression -> Html msg
renderBackslash latexState args =
    Html.span [] [ Html.text "\\", renderArg 0 latexState args ]    
 
renderTexArg : LatexState -> List LatexExpression -> Html msg
renderTexArg latexState args =
    Html.span [] [ Html.text "{", renderArg 0 latexState args, Html.text "}" ]    


renderNewCommand : LatexState -> List LatexExpression -> Html msg
renderNewCommand latexState args =
    let
        command =
            MeenyLatex.Render.renderArg 0 latexState args

        definition =
            MeenyLatex.Render.renderArg 1 latexState args
    in
        Html.span [] [ Html.text <| "\\newcommand{" ++ command ++ "}{" ++ definition ++ "}" ]


renderRef : LatexState -> List LatexExpression -> Html msg
renderRef latexState args =
    let
        key =
            MeenyLatex.Render.renderArg 0 latexState args
    in
        Html.span [] [ Html.text <| getCrossReference key latexState ]


docUrl : LatexState -> String 
docUrl latexState = 
  let 
      client = getDictionaryItem "setclient" latexState
      docId = getDictionaryItem "setdocid" latexState 
  in
      client ++ "/" ++ docId

idPhrase : String -> String -> String
idPhrase prefix name =
    let
        compressedName =
            name |> String.toLower |> String.replace " " "_"
    in
        makeId prefix name

renderSection : LatexState -> List LatexExpression -> Html msg
renderSection latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        s1 =
            getCounter "s1" latexState

        label =
            if s1 > 0 then
                String.fromInt s1 ++ " "
            else
                ""
        
        ref =
            idPhrase "section" sectionName
    in
        Html.h2 [ HA.id ref ] [ Html.text <| label ++ sectionName ]


renderSectionStar : LatexState -> List LatexExpression -> Html msg
renderSectionStar latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            idPhrase "section" sectionName
    in
        Html.h2 [ HA.id ref ] [ Html.text <| sectionName ]


renderSubsection : LatexState -> List LatexExpression -> Html msg
renderSubsection latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        s1 =
            getCounter "s1" latexState

        s2 =
            getCounter "s2" latexState

        label =
            if s1 > 0 then
                String.fromInt s1 ++ "." ++ String.fromInt s2 ++ " "
            else
                ""

        ref =
            idPhrase "subsection" sectionName
    in
        Html.h3 [ HA.id ref ] [ Html.text <| label ++ sectionName ]


renderSubsectionStar : LatexState -> List LatexExpression -> Html msg
renderSubsectionStar latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            idPhrase "subsection" sectionName
    in
        Html.h3 [ HA.id ref ] [ Html.text <| sectionName ]


renderSubSubsection : LatexState -> List LatexExpression -> Html msg
renderSubSubsection latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        s1 =
            getCounter "s1" latexState

        s2 =
            getCounter "s2" latexState

        s3 =
            getCounter "s3" latexState

        label =
            if s1 > 0 then
                String.fromInt s1 ++ "." ++ String.fromInt s2 ++ "." ++ String.fromInt s3 ++ " "
            else
                ""

        ref =
            idPhrase "subsubsection" sectionName
    in
        Html.h4 [ HA.id ref ] [ Html.text <| label ++ sectionName ]


renderSubSubsectionStar : LatexState -> List LatexExpression -> Html msg
renderSubSubsectionStar latexState args =
    let
        sectionName =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            idPhrase "subsubsection" sectionName
    in
        Html.h4 [ HA.id ref ] [ Html.text <| sectionName ]


renderDocumentTitle : LatexState -> List LatexExpression -> Html msg
renderDocumentTitle latexState list =
    let
        title =
            getDictionaryItem "title" latexState

        author =
            getDictionaryItem "author" latexState

        date =
            getDictionaryItem "date" latexState

        email =
            getDictionaryItem "email" latexState

        revision =
            getDictionaryItem "revision" latexState

        revisionText =
            if revision /= "" then
                "Last revised " ++ revision
            else
                ""

        titlePart =
            Html.div [ HA.class "title" ] [ Html.text title ]

        bodyParts =
            [ author, email, date, revisionText ]
                |> List.filter (\x -> x /= "")
                |> List.map (\x -> Html.li [] [ Html.text x ])

        bodyPart =
            Html.ul [] bodyParts
    in
        Html.div [] [ titlePart, bodyPart ]


renderSetCounter : LatexState -> List LatexExpression -> Html msg
renderSetCounter latexState list =
    Html.span [] []


renderSubheading : LatexState -> List LatexExpression -> Html msg
renderSubheading latexState args =
    let
        title =
            MeenyLatex.Render.renderArg 0 latexState args
    in
        Html.div [ HA.class "subheading" ] [ Html.text <| title ]


renderTitle : LatexState -> List LatexExpression -> Html msg
renderTitle latexState args =
    Html.span [] []


renderAuthor : LatexState -> List LatexExpression -> Html msg
renderAuthor latexState args =
    Html.span [] []   

renderSetDocId : LatexState -> List LatexExpression -> Html msg
renderSetDocId latexState args =
    Html.span [] []

renderSetClient : LatexState -> List LatexExpression -> Html msg
renderSetClient latexState args =
    Html.span [] []

renderDate : LatexState -> List LatexExpression -> Html msg
renderDate latexState args =
    Html.span [] []


renderRevision : LatexState -> List LatexExpression -> Html msg
renderRevision latexState args =
    Html.span [] []


renderEmail : LatexState -> List LatexExpression -> Html msg
renderEmail latexState args =
    Html.span [] []


renderTerm : LatexState -> List LatexExpression -> Html msg
renderTerm latexState args =
    let
        arg =
            MeenyLatex.Render.renderArg 0 latexState args
    in
        Html.i [] [ Html.text <| arg ]


renderXLink : LatexState -> List LatexExpression -> Html msg
renderXLink latexState args =
    let
        id =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            (getDictionaryItem "setclient" latexState) ++ "/" ++ id

        label =
            MeenyLatex.Render.renderArg 1 latexState args
    in
        Html.a [ Html.Attributes.href ref ] [ Html.text label ]


renderXLinkPublic : LatexState -> List LatexExpression -> Html msg
renderXLinkPublic latexState args =
    let
        id =
            MeenyLatex.Render.renderArg 0 latexState args

        ref =
            (getDictionaryItem "setclient" latexState) ++ "/" ++ id

        label =
            MeenyLatex.Render.renderArg 1 latexState args
    in
        Html.a [ Html.Attributes.href ref ] [ Html.text label ]



{- END OF INDIVIDUAL MACROS -}
{- SMACROS -}


renderSMacroDict : Dict.Dict String (LatexState -> List LatexExpression -> List LatexExpression -> LatexExpression -> Html msg)
renderSMacroDict =
    Dict.fromList
        [ ( "bibitem", \latexState optArgs args body -> renderBibItem latexState optArgs args body )
        ]


renderSMacro : LatexState -> String -> List LatexExpression -> List LatexExpression -> LatexExpression -> Html msg
renderSMacro latexState name optArgs args le =
    case Dict.get name renderSMacroDict of
        Just f ->
            f latexState optArgs args le

        Nothing ->
            reproduceSMacro name latexState optArgs args le


reproduceSMacro : String -> LatexState -> List LatexExpression -> List LatexExpression -> LatexExpression -> Html msg
reproduceSMacro name latexState optArgs args le =
    let
        renderedOptArgs =
            renderArgList latexState optArgs |> List.map enclose

        renderedArgs =
            renderArgList latexState args |> List.map enclose

        renderedLe =
            render latexState le |> enclose
    in
        Html.span []
            ([ Html.text <| "\\" ++ name ] ++ renderedOptArgs ++ renderedArgs ++ [ renderedLe ])


renderBibItem : LatexState -> List LatexExpression -> List LatexExpression -> LatexExpression -> Html msg
renderBibItem latexState optArgs args body =
    let
        label =
            if List.length optArgs == 1 then
                MeenyLatex.Render.renderArg 0 latexState optArgs
            else
                MeenyLatex.Render.renderArg 0 latexState args

        id =
            "bibitem:" ++ label
    in
        Html.p [ HA.id id ] [ Html.text <| "[" ++ label ++ "] " ++ (MeenyLatex.Render.render latexState body) ]



{- END RENDER INDIVIDUAL SMACROS -}
{- LISTS -}


itemClass : Int -> String
itemClass level =
    "item" ++ String.fromInt level


renderItem : LatexState -> Int -> LatexExpression -> Html msg
renderItem latexState level latexExpression =
    Html.li [ HA.class (itemClass level) ] [ render latexState latexExpression ]



{- END LISTS -}
{- BEGIN ENVIRONMENTS -}


renderEnvironment : LatexState -> String -> List LatexExpression -> LatexExpression -> Html msg
renderEnvironment latexState name args body =
    environmentRenderer name latexState args body


environmentRenderer : String -> (LatexState -> List LatexExpression -> LatexExpression -> Html msg)
environmentRenderer name =
    case Dict.get name renderEnvironmentDict of
        Just f ->
            f

        Nothing ->
            renderDefaultEnvironment name


renderDefaultEnvironment : String -> LatexState -> List LatexExpression -> LatexExpression -> Html msg
renderDefaultEnvironment name latexState args body =
    if List.member name [ "theorem", "proposition", "corollary", "lemma", "definition" ] then
        renderTheoremLikeEnvironment latexState name args body
    else
        renderDefaultEnvironment2 latexState (Utility.capitalize name) args body


renderTheoremLikeEnvironment : LatexState -> String -> List LatexExpression -> LatexExpression -> Html msg
renderTheoremLikeEnvironment latexState name args body =
    let
        r =
            render latexState body

        eqno =
            getCounter "eqno" latexState

        s1 =
            getCounter "s1" latexState

        tno =
            getCounter "tno" latexState

        tnoString =
            if s1 > 0 then
                " " ++ String.fromInt s1 ++ "." ++ String.fromInt tno
            else
                " " ++ String.fromInt tno
    in
        Html.div [ HA.class "environment" ]
            [ Html.strong [] [ Html.text ((Utility.capitalize name) ++ tnoString) ]
            , Html.div [ HA.class "italic" ] [ r ]
            ]


renderDefaultEnvironment2 : LatexState -> String -> List LatexExpression -> LatexExpression -> Html msg
renderDefaultEnvironment2 latexState name args body =
    let
        r =
            render latexState body
    in
        Html.div [ HA.class "environment" ]
            [ Html.strong [] [ Html.text name ]
            , Html.div [] [ r ]
            ]



{- INDIVIDUAL ENVIRONMENT RENDERERS -}


renderEnvironmentDict : Dict.Dict String (LatexState -> List LatexExpression -> LatexExpression -> Html msg)
renderEnvironmentDict =
    Dict.fromList
        [ ( "align", \x a y -> renderAlignEnvironment x y )
        , ( "center", \x a y -> renderCenterEnvironment x y )
        , ( "comment", \x a y -> renderCommentEnvironment x y )
        , ( "defitem", \x a y -> renderDefItemEnvironment x a y )
        , ( "enumerate", \x a y -> renderEnumerate x y )
        , ( "eqnarray", \x a y -> renderEqnArray x y )
        , ( "equation", \x a y -> renderEquationEnvironment x y )
        , ( "indent", \x a y -> renderIndentEnvironment x y )
        , ( "itemize", \x a y -> renderItemize x y )
        , ( "listing", \x a y -> renderListing x y )
        , ( "macros", \x a y -> renderMacros x y )
        , ( "maskforweb", \x a y -> renderCommentEnvironment x y )
        , ( "quotation", \x a y -> renderQuotation x y )
        , ( "tabular", \x a y -> renderTabular x y )
        , ( "thebibliography", \x a y -> renderTheBibliography x y )
        , ( "useforweb", \x a y -> renderUseForWeb x y )
        , ( "verbatim", \x a y -> renderVerbatim x y )
        , ( "verse", \x a y -> renderVerse x y )
        ]


renderAlignEnvironment : LatexState -> LatexExpression -> Html msg
renderAlignEnvironment latexState body =
    let
        r =
            MeenyLatex.Render.render latexState body

        eqno =
            getCounter "eqno" latexState

        s1 =
            getCounter "s1" latexState

        addendum =
            if eqno > 0 then
                if s1 > 0 then
                    "\\tag{" ++ String.fromInt s1 ++ "." ++ String.fromInt eqno ++ "}"
                else
                    "\\tag{" ++ String.fromInt eqno ++ "}"
            else
                ""

        content =
            "\n\\begin{align}\n" ++ addendum ++ r ++ "\n\\end{align}\n"
    in
        displayMathText content


renderCenterEnvironment : LatexState -> LatexExpression -> Html msg
renderCenterEnvironment latexState body =
    let
        r =
            render latexState body
    in
        Html.div [ HA.class "center" ] [ r ]


renderCommentEnvironment : LatexState -> LatexExpression -> Html msg
renderCommentEnvironment latexState body =
    Html.div [] []


renderEnumerate : LatexState -> LatexExpression -> Html msg
renderEnumerate latexState body =
    Html.ol [] [ render latexState body ]

renderDefItemEnvironment : LatexState -> List LatexExpression -> LatexExpression -> Html msg
renderDefItemEnvironment latexState optArgs body =
  Html.div []
    [   Html.strong [] [Html.text <| MeenyLatex.Render.renderArg 0 latexState optArgs]
      , Html.div [HA.style "margin-left" "25px", HA.style "margin-top" "15px"] [render latexState body]
    ]

{-| XXX
-}
renderEqnArray : LatexState -> LatexExpression -> Html msg
renderEqnArray latexState body =
    displayMathText (MeenyLatex.Render.render latexState body)


renderEquationEnvironment : LatexState -> LatexExpression -> Html msg
renderEquationEnvironment latexState body =
    let
        eqno =
            getCounter "eqno" latexState

        s1 =
            getCounter "s1" latexState

        addendum =
            if eqno > 0 then
                if s1 > 0 then
                    "\\tag{" ++ String.fromInt s1 ++ "." ++ String.fromInt eqno ++ "}"
                else
                    "\\tag{" ++ String.fromInt eqno ++ "}"
            else
                ""

        r =
            (MeenyLatex.Render.render latexState body)
    in
        displayMathText <| "\\begin{equation}" ++ r ++ addendum ++ "\\end{equation}"



-- "\n$$\n\\begin{equation}" ++ addendum ++ r ++ "\\end{equation}\n$$\n"


renderIndentEnvironment : LatexState -> LatexExpression -> Html msg
renderIndentEnvironment latexState body =
    Html.div [ HA.style "margin-left" "2em" ] [ render latexState body ]


renderItemize : LatexState -> LatexExpression -> Html msg
renderItemize latexState body =
    Html.ul [] [ render latexState body ]


renderListing : LatexState -> LatexExpression -> Html msg
renderListing latexState body =
    let
        text =
            MeenyLatex.Render.render latexState body

        lines =
            Utility.addLineNumbers text
    in
        Html.pre [ HA.class "verbatim" ] [ Html.text lines ]


renderMacros : LatexState -> LatexExpression -> Html msg
renderMacros latexState body =
    displayMathText (MeenyLatex.Render.render latexState body)


renderQuotation : LatexState -> LatexExpression -> Html msg
renderQuotation latexState body =
    Html.div [ HA.class "quotation" ] [ render latexState body ]


renderTabular : LatexState -> LatexExpression -> Html msg
renderTabular latexState body =
    Html.table [] [ renderTableBody body ]


renderCell : LatexExpression -> Html msg
renderCell cell =
    case cell of
        LXString s ->
            Html.td [] [ Html.text s ]

        InlineMath s ->
            Html.td [] [ inlineMathText s ]

        _ ->
            Html.td [] []


renderRow : LatexExpression -> Html msg
renderRow row =
    case row of
        LatexList row_ ->
            Html.tr [] (row_ |> List.map renderCell)

        _ ->
            Html.tr [] []


renderTableBody : LatexExpression -> Html msg
renderTableBody body =
    case body of
        LatexList body_ ->
            Html.tbody [] (body_ |> List.map renderRow)

        _ ->
            Html.tbody [] []


renderTheBibliography : LatexState -> LatexExpression -> Html msg
renderTheBibliography latexState body =
    Html.div [] [ render latexState body ]


renderUseForWeb : LatexState -> LatexExpression -> Html msg
renderUseForWeb latexState body =
    displayMathText (MeenyLatex.Render.render latexState body)


renderVerbatim : LatexState -> LatexExpression -> Html msg
renderVerbatim latexState body =
    let
        body2 =
            MeenyLatex.Render.render latexState body 
    in
        Html.pre [ HA.style "margin-top" "-13px", HA.style "font-size" "14px" ] [ Html.text body2 ]


renderVerse : LatexState -> LatexExpression -> Html msg
renderVerse latexState body =
    Html.div [ HA.class "verse" ] [ Html.text (String.trim <| MeenyLatex.Render.render latexState body) ]
