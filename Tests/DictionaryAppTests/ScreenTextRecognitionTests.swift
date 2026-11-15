import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import DictionaryApp

struct ScreenTextRecognitionTests {
    @MainActor
    @Test func windowLocalCropOwnsOnlyTheRequestedPixelsAcrossNegativeDisplayOrigins() throws {
        func image(outside:CGFloat) throws -> CGImage {
            let bitmap=try #require(CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:1600,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.setFillColor(CGColor(gray:1,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:400,height:200))
            bitmap.setFillColor(CGColor(gray:outside,alpha:1));bitmap.fill(CGRect(x:0,y:0,width:20,height:20))
            return try #require(bitmap.makeImage())
        }
        let window=CGRect(x:-600,y:-100,width:200,height:100),region=CGRect(x:-550,y:-75,width:80,height:40)
        let first=try #require(BooksScreenCapture.localCrop(image:try image(outside:0),window:window,region:region))
        let second=try #require(BooksScreenCapture.localCrop(image:try image(outside:0.5),window:window,region:region))
        #expect(first.region==region && first.image.width==160 && first.image.height==80)
        let pixels=try #require(first.image.dataProvider?.data) as Data
        #expect(pixels.count==160*80*4)
        #expect(pixels == (try #require(second.image.dataProvider?.data) as Data))
    }

    @Test func realVisionReadsOnlyAnInMemorySyntheticImage() async throws {
        let context=try #require(CGContext(data:nil,width:1000,height:360,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:1000,height:360))
        let font=CTFontCreateWithName("Helvetica" as CFString,28,nil)
        for (text,y) in [("The bank approved a loan.",CGFloat(280)),("They walked along the bank of the river.",CGFloat(150))] {
            let string=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
            context.textPosition=CGPoint(x:30,y:y)
            CTLineDraw(CTLineCreateWithAttributedString(string),context)
        }
        let image=try #require(context.makeImage())
        let snapshot=BooksScreenSnapshot(windowID:1,windowBounds:CGRect(x:0,y:0,width:1000,height:360),
            region:CGRect(x:0,y:0,width:1000,height:360),pointer:.zero,digest:Data(),image:image)
        let lines=await ScreenTextRecognition.lines(snapshot:snapshot,target:"bank",timeout:30)
        let river=try #require(lines.first { $0.text.contains("river") })
        let word=try #require(river.words.first)
        #expect(river.text == "They walked along the bank of the river.")
        #expect(river.confidence >= 0 && river.confidence <= 1)
        #expect(river.bounds.insetBy(dx:-0.5,dy:-0.5).contains(word.bounds))
        let sentence=ScreenTextContext.sentence(target:"bank",pointer:CGPoint(x:word.bounds.midX,y:word.bounds.midY),lines:lines)
        // Vision's confidence calibration differs between macOS versions. A
        // correct string is still insufficient evidence below the product gate.
        if river.confidence >= 0.85 {
            #expect(sentence == "They walked along the bank of the river.")
        } else {
            #expect(sentence == nil)
        }
        let region=CGRect(x:0,y:100,width:900,height:200)
        let crop=try #require(await BooksScreenCapture.localCrop(image:image,window:snapshot.windowBounds,region:region))
        let cropped=BooksScreenSnapshot(windowID:1,windowBounds:snapshot.windowBounds,region:crop.region,
            pointer:CGPoint(x:word.bounds.midX-region.minX,y:word.bounds.midY-region.minY),digest:Data(),image:crop.image)
        let croppedLines=await ScreenTextRecognition.lines(snapshot:cropped,target:"bank",timeout:30)
        let croppedRiver=try #require(croppedLines.first { $0.text.contains("river") })
        #expect(croppedRiver.text == "They walked along the bank of the river.")
        let croppedSentence=ScreenTextContext.sentence(target:"bank",pointer:cropped.pointer,lines:croppedLines)
        if croppedRiver.confidence >= 0.85 {
            #expect(croppedSentence == "They walked along the bank of the river.")
        } else {
            #expect(croppedSentence == nil)
        }
    }
}
