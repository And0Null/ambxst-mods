.pragma library

// The desktop widgets' shared rule: how big the type inside a card is.
//
// A card's size may only GROW the type, and only past the family's normal size — so the
// cards a design already places keep rendering the base sizes they always had, and a
// bigger card spends its extra room on bigger text instead of on more empty glass. Two
// caps keep that honest: the height it measures from (`referenceHeight`, the inner
// height of a normal card of that family) and the width the longest line needs once
// scaled, so growing never pushes text out of the card.
//
// Everything here is in the WIDGET's space, not the card's: WidgetFrame fills its
// content with anchors.margins 16, so an N-tall card hands the widget N-32. Mixing those
// two spaces is the trap this file exists to close — the first version of the clock's
// scale used a card height as its reference and grew 1.10 where 1.26 was intended.

var FRAME_MARGIN = 16;   // WidgetFrame's anchors.margins, on each side

// The box a card of this size hands to the widget inside it.
function innerHeight(cardHeight) {
    return cardHeight - FRAME_MARGIN * 2;
}

// Scale to multiply a widget's base font sizes by. `naturalWidth` is the longest line at
// its base size; 0 or a negative width means "no width constraint" (then only the height
// and the top clamp apply).
function typeScaleFor(width, height, naturalWidth, referenceHeight) {
    var byHeight = height / referenceHeight;
    // 0.98 keeps a hair of margin instead of landing the longest line exactly on the
    // card's edge, where a rounded-up glyph would elide.
    var byWidth = (naturalWidth > 0) ? (width * 0.98) / naturalWidth : 9;
    return Math.max(1.0, Math.min(1.8, Math.min(byHeight, byWidth)));
}
