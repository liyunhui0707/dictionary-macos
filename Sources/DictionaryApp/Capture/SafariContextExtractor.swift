import AppKit

/// Safari represents web-content text positions with `AXTextMarker` objects
/// rather than the integer ranges that `ContextExtractor` reads, so the
/// generic AX path can fetch the selection but not its surrounding
/// paragraph. This extractor asks Safari to execute a small JavaScript
/// snippet inside its current tab — essentially the same DOM walk the
/// Chromium extension performs — and returns the result.
///
/// Requires the user to enable Safari → Develop menu → "Allow JavaScript
/// from Apple Events" once, and to grant the Dictionary app Automation
/// permission for Safari (macOS will prompt on first attempt).
final class SafariContextExtractor {
    func extract() -> CapturedContext? {
        let asSource = Self.buildAppleScript(injecting: Self.injectionScript)

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: asSource) else { return nil }
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            // AppleScript errors can contain page data. The capture pipeline records a fixed category.
            return nil
        }

        guard let payload = result.stringValue, !payload.isEmpty else { return nil }
        return Self.decodeReply(payload)
    }

    // Internal seams exercise the production injection and decoder without Apple Events.
    static func decodeReply(_ payload: String) -> CapturedContext? {
        if payload.hasPrefix("ERR:") {
            return nil
        }

        guard let data = payload.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let reply = try? decoder.decode(SafariReply.self, from: data),
              reply.empty == false,
              let target = reply.target,
              !target.isEmpty else {
            return nil
        }
        guard let request = try? LookupRequest.captured(target: target, context: reply.context,
            sentence: reply.containingSentence, source: "Safari", capture: reply.capture ??
                .init(reliability: .legacyUnverified, method: .domRange)) else { return nil }
        return CapturedContext(target: request.target, context: request.context ?? request.target,
                               containingSentence: request.containingSentence, capture: request.capture)
    }

    static func buildAppleScript(injecting js: String) -> String {
        // AppleScript string literals escape `\` and `"` the same way C does;
        // we apply those escapes here so the JS source survives both the
        // Swift string and the AppleScript parser.
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Safari"
            if not (exists window 1) then return ""
            try
                return (do JavaScript "\(escaped)" in current tab of window 1)
            on error errMsg
                return "ERR:" & errMsg
            end try
        end tell
        """
    }

    private struct SafariReply: Decodable {
        let empty: Bool
        let target: String?
        let context: String?
        let containingSentence: String?
        let capture: SelectionLocation?

        private enum CodingKeys: String, CodingKey { case empty, target, context, containingSentence, capture }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            empty = try c.decode(Bool.self, forKey: .empty)
            target = try c.decodeIfPresent(String.self, forKey: .target)
            context = try c.decodeIfPresent(String.self, forKey: .context)
            containingSentence = try c.decodeIfPresent(String.self, forKey: .containingSentence)
            // A damaged optional claim must not discard an otherwise usable word.
            // Keep camelCase here: this bridge is distinct from HTTP's snake aliases.
            if c.contains(.capture), !(try c.decodeNil(forKey: .capture)) {
                capture = (try? c.decode(SelectionLocation.self, forKey: .capture)) ??
                    .init(reliability: .legacyUnverified, method: .domRange, reason: .metadataInvalid)
            } else { capture = nil }
        }
    }

    /// Standalone deployment of the reviewed DOM profile, with no page-text interpolation.
    /// Parity tests execute this exact value in WebKit and compare the deployed core.
    static let injectionScript: String = #"""
    (function(){
    // One bounded, contiguous raw Range is the coordinate space. Never filter or search
    // its text to reconstruct a selection. Unsupported projections retain only the word.
    const CAPTURE_EDGE = /^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$/g;
    const SOURCE_BREAK = /[\r\n\u0085\u2028\u2029\v\f]/;
    // No rendered-order map is available for explicit bidi effects in this profile.
    const BIDI_CONTROL = /[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/;
    const ABBREVIATIONS = new Set(['mr','mrs','ms','dr','prof','sr','jr','st','vs','etc','e.g','i.e',
        'capt','rev','gen','gov','sen','hon','adm','lt','col','maj','sgt','cpl','cmdr','rep','pres','fr']);
    function ambiguousPeriod(text) {
        const terminal = /\b([A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*)\.["'”’\])}]*[ \t]*$/.exec(text);
        if (!terminal) return false;
        const token = terminal[1];
        // A title/proper-name/initial, dotted token or numeral is not positive proof
        // of a sentence boundary. Unknown capitalized titles are withheld too, rather
        // than treating absence from a finite abbreviation list as proof of completeness.
        return ABBREVIATIONS.has(token.toLowerCase()) || /^[A-Z0-9]/.test(token) || token.includes('.') || !/[aeiouy]/i.test(token);
    }
    // A segmenter's internal full stop needs evidence on its right as well as its
    // left. Admit only this narrow English opening profile; a bare name, numeral or
    // continuation is unknown, never a complete boundary because a denylist missed it.
    function independentOpening(text) {
        const source = captureTrim(text);
        if (/^["'“‘([{]*(?:I|We|You|He|She|It|They|The|A|An|This|That|These|Those|There|Here)[ \t]+[A-Za-z]/.test(source)) return true;
        return false;
    }
    function supportedInternalBoundary(before, after) {
        if (/[!?]["'”’\])}]*[ \t]+$/.test(before)) return true;
        return /\.["'”’\])}]*[ \t]+$/.test(before) && !ambiguousPeriod(before) && independentOpening(after);
    }
    function unresolvedInteriorStop(text) {
        const final = /\.["'”’\])}]*[ \t]*$/.exec(text);
        for (let i=0;i<text.length;i++) {
            if (text[i]!=='.' || i===final?.index) continue;
            // Decimal points are not full stops. An additional possible full stop
            // makes a one-segment proposal unresolved; do not join or repair it.
            if (/[0-9]/.test(text[i-1] || '') && /[0-9]/.test(text[i+1] || '')) continue;
            return true;
        }
        return false;
    }
    const INLINE_TAGS = new Set(['A','SPAN','STRONG','EM','B','I','U','S','SMALL','MARK','ABBR','CITE','Q','CODE','SUB','SUP','TIME']);
    const BLOCK_TAGS = new Set(['P','DIV','ARTICLE','SECTION','BLOCKQUOTE','LI','TD','DD','DT','FIGCAPTION','H1','H2','H3','H4','H5','H6']);
    const MAX_CONTEXT_CHARS = 2000, MAX_SCAN_UNITS = 8000, MAX_NODES = 4000;
    function captureTrim(s) { return s.replace(CAPTURE_EDGE, ''); }
    function trimBounds(s, start = 0, end = s.length) {
        const raw = s.slice(start,end), trimmed = captureTrim(raw);
        if (!trimmed) return {start:end,end};
        // Edge arithmetic only; this is not a target/sentence string search.
        const left = raw.match(/^[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]*/)[0].length;
        return {start:start+left,end:start+left+trimmed.length};
    }
    function validSpan(s, r) {
        if (!r || !Number.isSafeInteger(r.start) || !Number.isSafeInteger(r.end) || r.start < 0 || r.start >= r.end || r.end > s.length) return false;
        const split = i => i > 0 && i < s.length && /[\uD800-\uDBFF]/.test(s[i-1]) && /[\uDC00-\uDFFF]/.test(s[i]);
        return !split(r.start) && !split(r.end);
    }
    function onlyTarget(target, reason) {
        return {empty:false,target,context:null,containingSentence:null,
            capture:{version:1,unit:'utf16',reliability:'targetOnly',method:'domRange',range:null,sentenceRange:null,reason}};
    }

    // Called with acquisition facts from the DOM adapter; also the pure R2 fixture seam.
    // Eligibility is decided BEFORE trimming/windowing; rejected evidence stays rejected.
    function captureRawText(raw, range, target, edges, crop = null) {
        if (BIDI_CONTROL.test(raw)) return onlyTarget(target,'unsupportedStructure');
        if (!validSpan(raw,range) || captureTrim(raw.slice(range.start,range.end)) !== target) return onlyTarget(target,'rangeMismatch');
        const trimmedSelection = trimBounds(raw,range.start,range.end);
        range = trimmedSelection;
        if (target.length > MAX_CONTEXT_CHARS || raw.length > MAX_SCAN_UNITS) return onlyTarget(target,'budgetExceeded');
        let sentence = null, scanSentenceCut = true;
        if (!SOURCE_BREAK.test(raw) && edges && !edges.snippet) {
            try {
                for (const p of new Intl.Segmenter('en',{granularity:'sentence'}).segment(raw)) {
                    const s = trimBounds(raw,p.index,p.index+p.segment.length);
                    if (s.start > range.start || s.end < range.end) continue;
                    const text = raw.slice(s.start,s.end), prefix = raw.slice(0,s.start);
                    const acquired = trimBounds(raw);
                    const atStart = s.start === acquired.start, atEnd = s.end === acquired.end;
                    scanSentenceCut = (atStart && !edges.leftComplete) || (atEnd && !edges.rightComplete);
                    const left = atStart ? edges.leftComplete : supportedInternalBoundary(prefix, raw.slice(s.start));
                    const right = atEnd ? edges.rightComplete : supportedInternalBoundary(raw.slice(0,s.end) + raw.slice(s.end).match(/^[ \t]*/)[0], raw.slice(s.end));
                    // Engine output is only a proposal. Reject fragments, ellipses and
                    // ambiguous abbreviations rather than manufacturing a sentence.
                    const capital = /^["'“‘([{]*[A-Z]/.test(text);
                    const terminal = /[.!?]["'”’\])}]*$/.test(text);
                    const ambiguous = ambiguousPeriod(text) || unresolvedInteriorStop(text) || /\.{2,}|…/.test(text);
                    if (left && right && capital && terminal && !ambiguous) sentence = s;
                    break;
                }
            } catch (_) { /* No sentence engine: preserve verified location only. */ }
        }
        if (!sentence && edges?.budgetCut && scanSentenceCut) return onlyTarget(target,'budgetExceeded');
        if (sentence && sentence.end-sentence.start > MAX_CONTEXT_CHARS) return onlyTarget(target,'budgetExceeded');
        const required = sentence || range;
        let start = crop ? crop.start : Math.max(0,Math.min(required.start,required.end-MAX_CONTEXT_CHARS));
        let end = crop ? crop.end : Math.min(raw.length,start+MAX_CONTEXT_CHARS);
        if (!crop && end === raw.length) start = Math.max(0,end-MAX_CONTEXT_CHARS);
        // Align inward to grapheme boundaries within the bounded raw candidate.
        try {
            const boundaries = [...new Intl.Segmenter('en',{granularity:'grapheme'}).segment(raw)].map(p=>p.index);
            boundaries.push(raw.length);
            start = boundaries.find(i=>i>=start);
            end = boundaries.filter(i=>i<=end).pop();
        } catch (_) {
            // A complete, uncut candidate needs no new grapheme boundary. Without
            // that engine, do not cut a larger candidate at guessed boundaries.
            if (start !== 0 || end !== raw.length) return onlyTarget(target,'unsupportedStructure');
        }
        if (start > required.start || end < required.end) return onlyTarget(target,'budgetExceeded');
        const trimmed = trimBounds(raw,start,end); start=trimmed.start; end=trimmed.end;
        if (start > range.start || end < range.end) return onlyTarget(target,'rangeMismatch');
        const context = raw.slice(start,end);
        const rebase = r => r && ({start:r.start-start,end:r.end-start});
        const finalRange = rebase(range), sentenceRange = rebase(sentence);
        if (!validSpan(context,finalRange) || context.slice(finalRange.start,finalRange.end) !== target) return onlyTarget(target,'rangeMismatch');
        if (context === target) return onlyTarget(target,'contextUnavailable');
        return {empty:false,target,context,containingSentence:sentence ? raw.slice(sentence.start,sentence.end) : null,
            capture:{version:1,unit:'utf16',reliability:'anchored',method:'domRange',range:finalRange,sentenceRange,
                     reason:sentence ? null : 'sentenceUnavailable'}};
    }

    function extractSelection() {
        const sel = window.getSelection();
        if (!sel || !sel.rangeCount || sel.isCollapsed) return {empty:true};
        const selectedString = sel.toString(), target = captureTrim(selectedString);
        if (!target) return {empty:true};
        const reject = reason => onlyTarget(target,reason);
        if (sel.rangeCount !== 1 || window.top !== window || target.length > MAX_CONTEXT_CHARS) return reject(target.length > MAX_CONTEXT_CHARS ? 'budgetExceeded' : 'unsupportedStructure');
        const original = sel.getRangeAt(0), r = original.cloneRange();
        const snapshot = [r.startContainer,r.startOffset,r.endContainer,r.endOffset];
        if (!snapshot[0].isConnected || !snapshot[2].isConnected || snapshot[0].ownerDocument !== document || snapshot[2].ownerDocument !== document) return reject('sourceChanged');
        const visited = new Set(), styles = new Map();
        function visit(n) { visited.add(n); if (visited.size > MAX_NODES) throw 'budgetExceeded'; }
        function style(el) { visit(el); if (!styles.has(el)) styles.set(el,getComputedStyle(el)); return styles.get(el); }
        function isBlock(el) { return BLOCK_TAGS.has(el.tagName) && ['block','list-item','table-cell'].includes(style(el).display); }
        try {
            let block = r.commonAncestorContainer.nodeType === Node.ELEMENT_NODE ? r.commonAncestorContainer : r.commonAncestorContainer.parentElement;
            let hops=0;
            while (block && !isBlock(block) && hops++ < 12) block=block.parentElement;
            if (!block || hops >= 12 || !block.contains(snapshot[0]) || !block.contains(snapshot[2])) return reject('unsupportedStructure');
            const checkedLocal=new Set(), checkedOuter=new Set();
            function check(el, local) {
                const checked=local ? checkedLocal : checkedOuter;
                if (checked.has(el)) return;
                const c=style(el);
                if (c.writingMode !== 'horizontal-tb' || c.direction !== 'ltr' || !['normal','isolate'].includes(c.unicodeBidi)) throw 'unsupportedStructure';
                if (el.hidden || ['none','contents'].includes(c.display) || c.visibility !== 'visible' || Number(c.opacity) !== 1 || c.contentVisibility !== 'visible' ||
                    (c.userSelect && !['auto','text'].includes(c.userSelect)) || (c.webkitUserSelect && !['auto','text'].includes(c.webkitUserSelect)) || parseFloat(c.fontSize) === 0 || c.textTransform !== 'none' || c.transform !== 'none' ||
                    c.clipPath !== 'none' || c.clip !== 'auto' || ['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY) ||
                    c.webkitLineClamp && c.webkitLineClamp !== 'none' || el.shadowRoot || el.tagName.includes('-')) throw 'unsupportedStructure';
                if (local) {
                    if (el !== block && (!INLINE_TAGS.has(el.tagName) || c.display !== 'inline')) throw 'unsupportedStructure';
                    if (['absolute','fixed','sticky'].includes(c.position) || c.float !== 'none' || c.columnCount !== 'auto' || c.columnWidth !== 'auto' ||
                        el.tagName === 'LI' && c.listStyleType !== 'none') throw 'unsupportedStructure';
                    for (const pseudo of ['::before','::after','::marker']) {
                        const content=getComputedStyle(el,pseudo).content;
                        if (content && !['none','normal','""'].includes(content)) throw 'unsupportedStructure';
                    }
                }
                checked.add(el);
            }
            function checkNode(n) {
                visit(n);
                let el=n.nodeType === Node.ELEMENT_NODE ? n : n.parentElement, depth=0;
                while (el) {
                    if (depth++ > 25) throw 'budgetExceeded';
                    check(el,true);
                    if (el===block) break;
                    el=el.parentElement;
                }
            }
            // Outer flex/grid positioning is allowed; ancestor suppression is not.
            let outer=block.parentElement; hops=0;
            while (outer && hops++ < 12) { check(outer,false); outer=outer.parentElement; }
            if (outer) return reject('budgetExceeded');
            const walker=document.createTreeWalker(block,NodeFilter.SHOW_ALL);
            function endpoint(container, offset, forward) {
                if (container.nodeType === Node.TEXT_NODE) return {node:container,offset};
                if (container.nodeType !== Node.ELEMENT_NODE) throw 'unsupportedStructure';
                let node=container.childNodes[forward ? offset : offset-1];
                if (!node) throw 'unsupportedStructure';
                // Resolve a child boundary to a text boundary without treating child
                // indices as character offsets. Unsupported empty structures fail closed.
                let depth=0;
                while (node.nodeType !== Node.TEXT_NODE) {
                    checkNode(node);
                    if (depth++ > 25) throw 'budgetExceeded';
                    node=forward ? node.firstChild : node.lastChild;
                    if (!node) throw 'unsupportedStructure';
                }
                return {node,offset:forward ? 0 : node.length};
            }
            const a=endpoint(snapshot[0],snapshot[1],true), b=endpoint(snapshot[2],snapshot[3],false);
            let selectedUnits=0;
            walker.currentNode=a.node;
            let n=a.node;
            while (n) {
                checkNode(n);
                if (n.nodeType===Node.TEXT_NODE) {
                    selectedUnits+=(n===b.node ? b.offset : n.length)-(n===a.node ? a.offset : 0);
                    if (selectedUnits > MAX_SCAN_UNITS) return reject('budgetExceeded');
                }
                if (n===b.node) break;
                n=walker.nextNode();
            }
            if (!n) return reject('rangeMismatch');
            // Acquire around the actual endpoints, including a late selection in one
            // enormous text node. No block.textContent/innerText or document prefix.
            const sideBudget=Math.floor((MAX_SCAN_UNITS-selectedUnits)/2);
            function expand(point, forward) {
                let node=point.node, offset=point.offset, remaining=sideBudget;
                walker.currentNode=node;
                while (node) {
                    checkNode(node);
                    if (node.nodeType===Node.TEXT_NODE) {
                        const available=forward ? node.length-offset : offset;
                        if (available > remaining) {
                            let cut=forward ? offset+remaining : offset-remaining;
                            // Find an observed ASCII grapheme break near the scan edge;
                            // never run a segmenter over an unbounded DOM text node.
                            const data=node.data; let steps=0;
                            while (cut>0 && cut<data.length && !(/[A-Za-z0-9.!?]/.test(data[cut-1]) && /[ \t]/.test(data[cut])) && steps++<128) cut+=forward ? -1 : 1;
                            if (steps>=128) throw 'budgetExceeded';
                            return {node,offset:cut,complete:false};
                        }
                        remaining-=available;
                        point={node,offset:forward ? node.length : 0};
                    }
                    node=forward ? walker.nextNode() : walker.previousNode();
                    if (node && node.nodeType===Node.TEXT_NODE) offset=forward ? 0 : node.length;
                }
                return {...point,complete:true};
            }
            const left=expand(a,false), right=expand(b,true);
            const candidate=document.createRange(); candidate.setStart(left.node,left.offset); candidate.setEnd(right.node,right.offset);
            const raw=candidate.toString();
            const prefix=candidate.cloneRange(); prefix.setEnd(r.startContainer,r.startOffset);
            const prefixEnd=candidate.cloneRange(); prefixEnd.setEnd(r.endContainer,r.endOffset);
            const range={start:prefix.toString().length,end:prefixEnd.toString().length};
            const rawSelected=r.toString();
            if (raw.length>MAX_SCAN_UNITS) return reject('budgetExceeded');
            if (!validSpan(raw,range) || raw.slice(range.start,range.end)!==rawSelected || captureTrim(rawSelected)!==target) return reject('rangeMismatch');
            // A cut hides incoming bidi state. Absence of controls in raw is NOT
            // proof that a prefix override stopped. Check the observed order of every
            // visible grapheme in this same bounded candidate, not a sample of bank.
            function orderedProjection() {
                const spans=[]; let units=0;
                walker.currentNode=left.node;
                let node=left.node;
                while (node) {
                    checkNode(node);
                    if (node.nodeType===Node.TEXT_NODE) {
                        const from=node===left.node ? left.offset : 0;
                        const to=node===right.node ? right.offset : node.length;
                        spans.push({node,from,start:units,end:units+to-from}); units+=to-from;
                    }
                    if (node===right.node) break;
                    node=walker.nextNode();
                }
                if (!node || units!==raw.length) return false;
                let cursor=0, previous=null;
                function point(offset) {
                    while (cursor+1<spans.length && offset>spans[cursor].end) cursor++;
                    const part=spans[cursor];
                    return {node:part.node,offset:part.from+offset-part.start};
                }
                try {
                    for (const piece of new Intl.Segmenter('en',{granularity:'grapheme'}).segment(raw)) {
                        if (!captureTrim(piece.segment)) continue;
                        const a=point(piece.index), b=point(piece.index+piece.segment.length);
                        const glyph=document.createRange(); glyph.setStart(a.node,a.offset); glyph.setEnd(b.node,b.offset);
                        const boxes=[...glyph.getClientRects()].filter(r=>r.width>0 && r.height>0);
                        if (boxes.length!==1) return false;
                        const box=boxes[0];
                        if (![box.left,box.right,box.top,box.bottom].every(Number.isFinite)) return false;
                        if (previous) {
                            const overlap=Math.min(box.bottom,previous.bottom)-Math.max(box.top,previous.top);
                            if (overlap>Math.min(box.height,previous.height)/2) {
                                // Native character boxes can overlap from kerning and
                                // pixel rounding. Require strictly advancing centers;
                                // tied/shared boxes are unestablished order, not proof.
                                if ((box.left+box.right)/2<=(previous.left+previous.right)/2) return false;
                            } else if (box.top<previous.bottom-0.5) return false;
                        }
                        previous=box;
                    }
                } catch (_) { return false; }
                return previous!==null;
            }
            if (BIDI_CONTROL.test(raw) || ((!left.complete || !right.complete) && !orderedProjection())) return reject('unsupportedStructure');
            const reply=captureRawText(raw,range,target,{leftComplete:left.complete,rightComplete:right.complete,budgetCut:!left.complete || !right.complete});
            const now=sel.rangeCount===1 && sel.getRangeAt(0);
            if (!now || !block.isConnected || snapshot[0]!==now.startContainer || snapshot[1]!==now.startOffset || snapshot[2]!==now.endContainer || snapshot[3]!==now.endOffset || sel.toString()!==selectedString || candidate.toString()!==raw) return reject('sourceChanged');
            return reply;
        } catch (reason) {
            return reject(['budgetExceeded','rangeMismatch','sourceChanged'].includes(reason) ? reason : 'unsupportedStructure');
        }
    }


    return JSON.stringify(extractSelection());
    })()
    """#
}
