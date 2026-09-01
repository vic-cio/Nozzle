import Testing
import Foundation
@testable import NozzleCore

@Suite("Modal G-code state")
struct GCodeModalStateTests {

    @Test("G90 and G91 are tracked, and stay set until changed")
    func positioningMode() {
        var state = GCodeModalState()
        #expect(state.relativeMoves == false)   // Marlin boots absolute

        state.observe("G91")
        #expect(state.relativeMoves)
        state.observe("G1 X10 Y10")
        #expect(state.relativeMoves, "an ordinary move must not clear the flag")
        state.observe("G90")
        #expect(state.relativeMoves == false)
    }

    @Test("M82 and M83 are tracked separately from G90 and G91")
    func extrusionModeIsIndependent() {
        var state = GCodeModalState()
        state.observe("M83")
        #expect(state.relativeExtrusion)
        #expect(state.relativeMoves == false)

        // G90 is about the axes; it says nothing about the extruder. Conflating the two
        // is the classic way to turn a 5 mm retract into a move to E5.
        state.observe("G90")
        #expect(state.relativeExtrusion)
    }

    @Test("M8 is not mistaken for M83")
    func commandNumbersAreMatchedExactly() {
        var state = GCodeModalState()
        state.observe("M8")
        #expect(state.relativeExtrusion == false)
        state.observe("M84")
        #expect(state.relativeExtrusion == false)
    }

    @Test("The feedrate carries forward from the last move that set one")
    func feedrateIsModal() {
        var state = GCodeModalState()
        #expect(state.feedrate == nil)

        state.observe("G1 X10 Y10 F1500")
        #expect(state.feedrate == 1500)

        // Cura only writes F when the speed changes, so a move without one is printing
        // at the previous feedrate — not at no feedrate.
        state.observe("G1 X20 Y20 E1")
        #expect(state.feedrate == 1500)

        state.observe("G0 F7200")
        #expect(state.feedrate == 7200)
    }

    @Test("Comments never change the state")
    func commentsAreIgnored() {
        var state = GCodeModalState()
        state.observe(";G91 this is only a comment")
        state.observe(";LAYER:4")
        state.observe("G1 X10 F1200 ;F9999 in a comment")
        #expect(state.relativeMoves == false)
        #expect(state.feedrate == 1200)
    }

    @Test("A parameter letter is only read when it starts a word")
    func parameterScanning() {
        // The E of a hypothetical word must not be read as an F, and the unspaced form
        // Marlin also accepts must still parse.
        #expect(GCodeModalState.value(of: "F", in: "G1X10Y10F1500") == 1500)
        #expect(GCodeModalState.value(of: "E", in: "G1 X10 E-2.5") == -2.5)
        #expect(GCodeModalState.value(of: "F", in: "G1 X10 Y10") == nil)
    }

    @Test("Replaying a file's header gives the state the first layer starts in")
    func replayingAHeader() {
        let header = [
            ";FLAVOR:Marlin",
            "M82 ;absolute extrusion mode",
            "G28",
            "G92 E0",
            "G1 F2400 E-5",
            "M83 ;relative extrusion mode",
        ]
        let state = GCodeModalState.replaying(header, through: header.count - 1)
        #expect(state.relativeExtrusion, "Cura's header ends in relative extrusion")
        #expect(state.relativeMoves == false)
        #expect(state.feedrate == 2400)
    }
}
