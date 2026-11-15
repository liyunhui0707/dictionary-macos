import Foundation
import Testing
@testable import DictionaryApp

struct ScreenTextContextTests {
    private func line(_ text: String, y: CGFloat, word: String = "bank", x: CGFloat = 180,
                      left: CGFloat = 10, confidence: Float = 0.99) -> ScreenTextLine {
        .init(text: text, bounds: CGRect(x: left,y:y,width:450,height:20), confidence:confidence,
              words: [.init(text:word,bounds:CGRect(x:x,y:y,width:40,height:20))])
    }

    @Test func pointerIdentifiesSecondOccurrenceAcrossSeparateParagraphs() {
        let lines = [line("The bank approved a loan.", y:10),
                     line("They walked along the bank of the river.", y:80)]
        #expect(ScreenTextContext.sentence(target:"bank", pointer:CGPoint(x:195,y:90),lines:lines) ==
                "They walked along the bank of the river.")
    }

    @Test func wrappedSentenceIsReconstructedWithoutJoiningOtherColumns() {
        let lines = [line("They walked along the bank",y:10),
                     line("of the river.",y:35,word:"river",x:50),
                     line("She deposited savings at the bank.",y:10,left:650)]
        #expect(ScreenTextContext.sentence(target:"bank",pointer:CGPoint(x:195,y:20),lines:lines) ==
                "They walked along the bank of the river.")
    }

    @Test(arguments:["farPointer","ambiguousAnchor","lowConfidence","fragment","repeatedSentence","substring","tooMany","badGeometry"])
    func uncertainPixelsDoNotSupplyAContext(mode:String) {
        var lines=[line("They walked along the bank of the river.",y:10)]
        var pointer=CGPoint(x:195,y:20)
        switch mode {
        case "farPointer": pointer=CGPoint(x:700,y:300)
        case "ambiguousAnchor": lines.append(line("Another bank closed.",y:30))
        case "lowConfidence": lines=[line("They walked along the bank of the river.",y:10,confidence:0.4)]
        case "fragment": lines=[line("the bank of the",y:10)]
        case "repeatedSentence": lines=[line("The bank closed beside another bank.",y:10)]
        case "substring": lines=[line("The bankruptcy ended.",y:10,word:"bankruptcy")]
        case "tooMany": lines=Array(repeating:lines[0],count:201)
        case "badGeometry": pointer=CGPoint(x:CGFloat.nan,y:20)
        default: break
        }
        #expect(ScreenTextContext.sentence(target:"bank",pointer:pointer,lines:lines) == nil)
    }

    @Test func missingBeginningAndDistantParagraphAreNotPatchedTogether() {
        let lines=[line("The bank opened",y:10),line("and closed later.",y:110,word:"later")]
        #expect(ScreenTextContext.sentence(target:"bank",pointer:CGPoint(x:195,y:20),lines:lines)==nil)
    }
}
