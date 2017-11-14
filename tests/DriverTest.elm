module DriverTest exposing (..)

import MiniLatex.Driver exposing (..)


-- http://package.elm-lang.org/packages/elm-community/elm-test/latest

import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer, list, int, string)
import Test exposing (..)


suite : Test
suite =
    describe "MiniLatex Driver"
        -- Nest as many descriptions as you like.
        [ test "(E.1) Render equation" <|
            \_ ->
                let
                    input =
                        """
\\begin{equation}
\\label{integral}
\\int_0^1 x^n dx = \\frac{1}{n+1}
\\end{equation}
"""

                    output =
                        render input

                    expectedOutput =
                        "\n<p>\n \n$$\n\\begin{equation}\\tag{1}\n\\label{integral}\n\\int_0^1 x^n dx = \\frac{1}{n+1}\n\\end{equation}\n$$\n</p>"
                in
                    Expect.equal output expectedOutput
        ]
