"use strict";

// Obsidian plugin for the local Dictionary macOS app.
//
// Obsidian is an Electron app, so the browser extension can't reach it and the
// Mac app's Accessibility path can't read CodeMirror's selection range. This
// plugin reads the selection + surrounding paragraph (with full DOM/editor
// access) and POSTs it to the same localhost server the browser extension
// uses. The Mac app shows the translation popup on success.

const { Plugin, PluginSettingTab, Setting, Notice, requestUrl, MarkdownView } = require("obsidian");

const SERVER_URL = "http://127.0.0.1:49152/v1/translate";
const DEFAULT_SETTINGS = { tokenSecretId: "" };
const validSecretId = value => typeof value === 'string' && /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value) && value.length <= 128;

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


// Public Editor positions address raw Markdown, never stripped/rendered text.
// The same route serves Source and Live Preview without private CodeMirror access.
function extractFromEditor(editor) {
    const selected=editor.getSelection() || '', target=captureTrim(selected);
    if (!target) return {empty:true};
    const reject=reason=>{const r=onlyTarget(target,reason);r.capture.method='editorRange';return r;};
    try {
        const selections=editor.listSelections();
        if (selections.length!==1) return reject('ambiguousOccurrence');
        const count=editor.lineCount(), cache=new Map();
        const line=i=>{if(!cache.has(i)){if(cache.size>=MAX_NODES)throw 'budgetExceeded';cache.set(i,editor.getLine(i));}return cache.get(i);};
        const copy=p=>({line:p.line,ch:p.ch});
        const from=copy(editor.getCursor('from')), to=copy(editor.getCursor('to'));
        const valid=p=>Number.isSafeInteger(p.line)&&Number.isSafeInteger(p.ch)&&p.line>=0&&p.line<count&&p.ch>=0&&p.ch<=line(p.line).length;
        const compare=(a,b)=>a.line-b.line || a.ch-b.ch;
        const same=(a,b)=>a.line===b.line&&a.ch===b.ch;
        const anchor=copy(selections[0].anchor), head=copy(selections[0].head);
        if (![from,to,anchor,head].every(valid) || compare(from,to)>=0 ||
            !same(from,compare(anchor,head)<=0?anchor:head) || !same(to,compare(anchor,head)<=0?head:anchor)) return reject('rangeMismatch');
        if (target.length>MAX_CONTEXT_CHARS || selected.length>MAX_SCAN_UNITS || to.line-from.line>=MAX_NODES) return reject('budgetExceeded');
        // Bound the selected span before invoking getRange on a possibly stale API.
        let units=0;
        for(let i=from.line;i<=to.line;i++){
            units+=(i===to.line?to.ch:line(i).length)-(i===from.line?from.ch:0)+(i===to.line?0:1);
            if(units>MAX_SCAN_UNITS) return reject('budgetExceeded');
        }
        if(units!==selected.length || editor.getRange(from,to)!==selected) return reject('rangeMismatch');
        const sideBudget=Math.floor((MAX_SCAN_UNITS-units)/2);
        function expand(point,forward){
            let p=copy(point), remaining=sideBudget;
            while(true){
                const text=line(p.line), available=forward?text.length-p.ch:p.ch;
                if(available>remaining){
                    let cut=forward?p.ch+remaining:p.ch-remaining,steps=0;
                    while(cut>0&&cut<text.length&&!(/[A-Za-z0-9.!?]/.test(text[cut-1])&&/[ \t]/.test(text[cut]))&&steps++<128)cut+=forward?-1:1;
                    if(steps>=128)throw 'budgetExceeded';
                    return {pos:{line:p.line,ch:cut},complete:false};
                }
                remaining-=available;p.ch=forward?text.length:0;
                const next=p.line+(forward?1:-1);
                if(next<0||next>=count)return {pos:p,complete:true};
                // Boundary support shares this side's remaining text budget.
                if(line(next).length<=remaining&&!captureTrim(line(next)))return {pos:p,complete:true};
                if(remaining<1)return {pos:p,complete:false};
                remaining--;p={line:next,ch:forward?0:line(next).length};
            }
        }
        const left=expand(from,false),right=expand(to,true);
        const raw=editor.getRange(left.pos,right.pos);
        const range={start:editor.getRange(left.pos,from).length,end:editor.getRange(left.pos,to).length};
        // Source coordinates are still useful where Markdown decoration, line
        // separators or unknown incoming display state cannot qualify a sentence.
        const uncertain=/[*_`~#[\]<>\\|{}]/.test(raw)||!left.complete||!right.complete;
        const reply=captureRawText(raw,range,target,{leftComplete:left.complete,rightComplete:right.complete,snippet:uncertain});
        reply.capture.method='editorRange';
        const now=editor.listSelections();
        if(editor.lineCount()!==count||now.length!==1||!same(anchor,now[0].anchor)||!same(head,now[0].head)||
            editor.getSelection()!==selected||editor.getRange(left.pos,right.pos)!==raw) return reject('sourceChanged');
        return reply;
    } catch(reason){return reject(['budgetExceeded','rangeMismatch','sourceChanged'].includes(reason)?reason:'unsupportedStructure');}
}

// Reading uses the reviewed Chromium profile, scoped to the active public preview root.
function extractFromDOM(root) {
    if (!root?.isConnected || root.ownerDocument!==document) return {empty:true};
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed) return {empty:true};
    if (!root.contains(sel.anchorNode) || !root.contains(sel.focusNode)) return {empty:true};
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
        if (!block || !root.contains(block) || hops >= 12 || !block.contains(snapshot[0]) || !block.contains(snapshot[2])) return reject('unsupportedStructure');
        const checkedLocal=new Set(), checkedOuter=new Set(), clippedAncestors=[];
        function check(el, local) {
            const checked=local ? checkedLocal : checkedOuter;
            if (checked.has(el)) return;
            const c=style(el);
            if (c.writingMode !== 'horizontal-tb' || c.direction !== 'ltr' || !['normal','isolate'].includes(c.unicodeBidi)) throw 'unsupportedStructure';
            if (el.hidden || ['none','contents'].includes(c.display) || c.visibility !== 'visible' || Number(c.opacity) !== 1 || c.contentVisibility !== 'visible' ||
                (c.userSelect && !['auto','text'].includes(c.userSelect)) || (c.webkitUserSelect && !['auto','text'].includes(c.webkitUserSelect)) || parseFloat(c.fontSize) === 0 || c.textTransform !== 'none' || c.transform !== 'none' ||
                c.clipPath !== 'none' || c.clip !== 'auto' || local && (['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY)) ||
                c.webkitLineClamp && c.webkitLineClamp !== 'none' || el.shadowRoot || el.tagName.includes('-')) throw 'unsupportedStructure';
            if (!local && (['hidden','clip'].includes(c.overflowX) || ['hidden','clip'].includes(c.overflowY))) {
                clippedAncestors.push({el,x:c.overflowX!=='visible',y:c.overflowY!=='visible'});
            }
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
        // Obsidian pane clipping is safe only when this entire raw candidate fits.
        // Keep local clipping/hidden text guards; never repair a clipped sentence.
        if (clippedAncestors.length) {
            const rects=[...candidate.getClientRects()];
            if (rects.length>MAX_NODES) return reject('budgetExceeded');
            if (rects.some(r=>![r.left,r.right,r.top,r.bottom,r.width,r.height].every(Number.isFinite) || r.width<0 || r.height<0)) return reject('unsupportedStructure');
            const visible=rects.filter(r=>r.width>0 && r.height>0);
            if (!visible.length) return reject('unsupportedStructure');
            for (const {el,x,y} of clippedAncestors) {
                const box=el.getBoundingClientRect();
                const left=box.left+el.clientLeft, top=box.top+el.clientTop;
                const right=left+el.clientWidth, bottom=top+el.clientHeight;
                if (![left,top,right,bottom].every(Number.isFinite) || right<=left || bottom<=top ||
                    visible.some(r=>x && (r.left<left || r.right>right) || y && (r.top<top || r.bottom>bottom))) return reject('unsupportedStructure');
            }
        }
        const reply=captureRawText(raw,range,target,{leftComplete:left.complete,rightComplete:right.complete,budgetCut:!left.complete || !right.complete});
        const now=sel.rangeCount===1 && sel.getRangeAt(0);
        if (!now || !root.isConnected || !root.contains(snapshot[0]) || !root.contains(snapshot[2]) || !block.isConnected || snapshot[0]!==now.startContainer || snapshot[1]!==now.startOffset || snapshot[2]!==now.endContainer || snapshot[3]!==now.endOffset || sel.toString()!==selectedString || candidate.toString()!==raw) return reject('sourceChanged');
        return reply;
    } catch (reason) {
        return reject(['budgetExceeded','rangeMismatch','sourceChanged'].includes(reason) ? reason : 'unsupportedStructure');
    }
}

module.exports = class DictionaryPlugin extends Plugin {
    async initializeCredentials() {
        this.credentialsBlocked = true;
        this.settings = {...DEFAULT_SETTINGS};
        try {
            const loaded = await this.loadData() || {};
            if (typeof loaded !== 'object' || Array.isArray(loaded)) throw Error();
            const {token: legacy, ...clean} = loaded;
            this.settings = Object.assign({}, DEFAULT_SETTINGS, clean);
            const storage = this.app?.secretStorage;
            if (typeof storage?.getSecret !== 'function' || typeof storage?.setSecret !== 'function') throw Error();
            if (typeof this.settings.tokenSecretId !== 'string' || this.settings.tokenSecretId && !validSecretId(this.settings.tokenSecretId)) throw Error();
            if (Object.hasOwn(loaded, 'token')) {
                if (typeof legacy !== 'string') throw Error();
                const value = legacy.trim();
                if (value) {
                    const id = this.settings.tokenSecretId || 'dictionary-lookup-' + crypto.randomUUID();
                    const existing = await storage.getSecret(id);
                    if (existing && existing !== value) throw Error();
                    await storage.setSecret(id, value);
                    if (await storage.getSecret(id) !== value) throw Error();
                    this.settings.tokenSecretId = id;
                }
                // Clear legacy plaintext only after a verified secure-store write.
                await this.saveData(this.settings);
                const persisted = await this.loadData();
                if (!persisted || Object.hasOwn(persisted, 'token') || persisted.tokenSecretId !== this.settings.tokenSecretId) throw Error();
            }
            this.credentialsBlocked = false;
        } catch (_) {
            // Never expose storage errors: an exception may contain a credential.
        }
    }

    async onload() {
        this.credentialReady = this.initializeCredentials();
        await this.credentialReady;
        this.addSettingTab(new DictionarySettingTab(this.app, this));

        this.addCommand({
            id: "translate-selection",
            name: "Translate selection",
            hotkeys: [{ modifiers: ["Alt"], key: "D" }],
            callback: () => {
                const view=this.app.workspace.getActiveViewOfType(MarkdownView);
                if(!view)return this.lookup({empty:true});
                const mode=view.getMode(), root=view.previewMode?.containerEl;
                const payload=mode==='source'
                    ? (view.editor?.hasFocus()?extractFromEditor(view.editor):{empty:true})
                    : mode==='preview'?extractFromDOM(root):{empty:true};
                if(this.app.workspace.getActiveViewOfType(MarkdownView)!==view || view.getMode()!==mode || mode==='preview'&&view.previewMode?.containerEl!==root)return this.lookup({empty:true});
                return this.lookup(payload);
            }
        });
    }

    async lookup(payload) {
        if (!payload || payload.empty) {
            new Notice("Dictionary: no text selected. Highlight a word or phrase first.");
            return;
        }
        await this.credentialReady;
        let token;
        try {
            if (this.credentialsBlocked || !validSecretId(this.settings?.tokenSecretId)) throw Error();
            token = await this.app.secretStorage.getSecret(this.settings.tokenSecretId);
            if (typeof token !== 'string' || !token.trim()) throw Error();
            token = token.trim();
        } catch (_) {
            new Notice("Dictionary: secure credential unavailable. Check SecretStorage or reload after resolving migration.");
            return;
        }

        let response;
        try {
            response = await requestUrl({
                url: SERVER_URL,
                method: "POST",
                throw: false,
                headers: {
                    "Content-Type": "application/json",
                    "Authorization": `Bearer ${token}`
                },
                body: JSON.stringify({
                    target: payload.target,
                    context: payload.context,
                    containingSentence: payload.containingSentence,
                    sourceApp: "Obsidian",
                    capture: payload.capture
                })
            });
        } catch (err) {
            new Notice("Dictionary app is not running. Launch it from Spotlight, then try again.");
            return;
        }

        if (response.status === 401) {
            new Notice("Dictionary: credential rejected. Update the referenced SecretStorage entry.");
            return;
        }
        if (response.status === 503) {
            let detail = "unknown";
            try { detail = response.json?.error || detail; } catch (e) { /* ignore */ }
            new Notice(`Dictionary: translation service error (${detail}).`);
            return;
        }
        if (response.status < 200 || response.status >= 300) {
            new Notice(`Dictionary: server returned ${response.status}.`);
            return;
        }
        // 200 — the Mac app shows the popup. Nothing else to do here.
    }
};

class DictionarySettingTab extends PluginSettingTab {
    constructor(app, plugin) {
        super(app, plugin);
        this.plugin = plugin;
    }

    display() {
        const { containerEl } = this;
        containerEl.empty();
        if (this.plugin.credentialsBlocked) {
            new Setting(containerEl).setName("Secure credential migration stopped")
                .setDesc("No queries will be sent. Resolve SecretStorage access and reload the plugin.");
            return;
        }
        new Setting(containerEl)
            .setName("Token secret ID")
            .setDesc("Only a non-secret reference is stored here. Manage the credential in Obsidian SecretStorage.")
            .addText((text) => text
                .setPlaceholder("dictionary-lookup-token")
                .setValue(this.plugin.settings.tokenSecretId)
                .onChange(async (value) => {
                    const id = value.trim();
                    if (id && !validSecretId(id)) return;
                    const clean = {...this.plugin.settings, tokenSecretId: id};
                    delete clean.token;
                    try {
                        await this.plugin.saveData(clean);
                        this.plugin.settings = clean;
                    } catch (_) {
                        this.plugin.credentialsBlocked = true;
                        new Notice("Dictionary: secure credential settings could not be saved.");
                    }
                }));
    }
}
