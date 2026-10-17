import Cocoa

// Panels follow macOS: window background, grouped cards, and floating popover-like bubbles that adapt
// to light and dark mode. `card` marks a grouped card, `dark` a floating bubble (badge, voice, hints).
final class EchoSurface:NSView {
    var radius:CGFloat=EchoUI.windowRadius, dark=false, card=false
    override func draw(_ dirtyRect:NSRect) {
        let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:radius,yRadius:radius)
        (dark ? EchoUI.floatingFill : (card ? EchoUI.cardFill : EchoUI.windowFill)).setFill(); shape.fill()
        EchoUI.stroke.setStroke(); shape.lineWidth=1; shape.stroke()
    }
}

// Selectable option chip. It draws its own fill because floating panels never become key,
// and AppKit only paints a default button's accent colour in the key window.
final class EchoChip:NSButton {
    var selected=false { didSet { needsDisplay=true } }
    override func draw(_ dirtyRect:NSRect) {
        (selected ? NSColor.controlAccentColor : EchoUI.chipFill).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:EchoUI.chipRadius,yRadius:EchoUI.chipRadius).fill()
        let text=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:12,weight:selected ? .semibold : .medium),.foregroundColor:selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor])
        let size=text.size(); text.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2))
    }
    override var intrinsicContentSize:NSSize { NSSize(width:ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold)]).width)+24,height:24) }
}

final class EchoWaveform:NSView {
    var power:Float = -160 { didSet { needsDisplay=true } }
    var phase:Double=0
    override func draw(_ dirtyRect:NSRect) {
        let level=CGFloat(max(0,min(1,(power+60)/45)))
        NSColor.controlAccentColor.setFill()
        for i in 0..<5 {
            let modulation=CGFloat(0.3+0.7*abs(sin(Double(i)*1.2+phase+Double(power)*0.13)))
            let height:CGFloat=3+(2+level*18)*modulation
            let step=bounds.width/5, bar=min(2.5,step*0.55)
            NSBezierPath(roundedRect:NSRect(x:CGFloat(i)*step,y:(bounds.height-height)/2,width:bar,height:height),xRadius:bar/2,yRadius:bar/2).fill()
        }
    }
}

enum EchoUI {
    static func brandImage(_ name:String)->NSImage {
        guard let url=Bundle.main.url(forResource:name,withExtension:"png"),let image=NSImage(contentsOf:url) else {
            assertionFailure("Missing APT brand resource: \(name)")
            return NSImage(size:NSSize(width:1,height:1))
        }
        return image
    }
    static func agentView(size:CGFloat)->NSImageView {
        let view=NSImageView(image:brandImage("APTAgent")); view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant:size),view.heightAnchor.constraint(equalToConstant:size)])
        view.setAccessibilityElement(false)
        return view
    }
    // Shared look, aligned with macOS: system accent, system fonts, adaptive fills.
    static let margin:CGFloat=22, padding:CGFloat=16, windowRadius:CGFloat=0, cardRadius:CGFloat=12, floatingRadius:CGFloat=14, chipRadius:CGFloat=7
    static func dynamic(_ light:NSColor,_ dark:NSColor)->NSColor { NSColor(name:nil) { $0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark : light } }
    static let windowFill=NSColor.windowBackgroundColor
    static let cardFill=dynamic(.white,NSColor(srgbRed:0.17,green:0.17,blue:0.18,alpha:1))
    static let floatingFill=dynamic(NSColor(white:0.99,alpha:0.98),NSColor(srgbRed:0.17,green:0.17,blue:0.18,alpha:0.98))
    static let chipFill=dynamic(NSColor.black.withAlphaComponent(0.06),NSColor.white.withAlphaComponent(0.10))
    static let stroke=dynamic(NSColor.black.withAlphaComponent(0.10),NSColor.white.withAlphaComponent(0.12))
    static func label(_ text:String,size:CGFloat=13,weight:NSFont.Weight = .regular,secondary:Bool=false)->NSTextField {
        let field=NSTextField(labelWithString:text); field.font = .systemFont(ofSize:size,weight:weight); field.textColor=secondary ? .secondaryLabelColor : .labelColor; return field
    }
    // Multi-line text that wraps and ends with an ellipsis after `lines` lines.
    static func wrapping(_ field:NSTextField,lines:Int) {
        field.maximumNumberOfLines=lines; field.lineBreakMode = .byWordWrapping; field.cell?.wraps=true; field.cell?.truncatesLastVisibleLine=true
    }
    static func fittingHeight(_ field:NSTextField,width:CGFloat) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:width,height:10_000)).height ?? 0)
    }
    static func icon(_ button:NSButton,_ name:String,label:String) {
        button.title=""; button.image=NSImage(systemSymbolName:name,accessibilityDescription:label)
        button.imagePosition = .imageOnly; button.isBordered=false; button.contentTintColor = .secondaryLabelColor; button.toolTip=label
        button.setAccessibilityLabel(label); button.refusesFirstResponder=true
    }
    // Borderless text action (link style); readable in never-key panels, unlike .inline bezels.
    static func textButton(_ button:NSButton,_ title:String,color:NSColor = .controlAccentColor,size:CGFloat=12) {
        button.isBordered=false; button.refusesFirstResponder=true; button.title=title
        button.attributedTitle=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:color])
    }
    static func primary(_ button:NSButton) { button.bezelStyle = .rounded; button.bezelColor = .controlAccentColor; button.contentTintColor = .alternateSelectedControlTextColor }
}

// Brief bubble under the caret, like macOS's input-source indicator: 中/英 after a switch, or a
// one-line reason when a shortcut cannot run. Never takes focus or clicks.
final class EchoHint {
    static let shared=EchoHint()
    let panel=MemoryCandidatePanel(contentRect:NSRect(x:0,y:0,width:34,height:26),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    let surface=EchoSurface(), label=EchoUI.label("")
    var hiding:DispatchWorkItem?
    init() {
        surface.dark=true; surface.radius=7; surface.addSubview(label); label.alignment = .center
        panel.contentView=surface; panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true; panel.level = .floating
        panel.ignoresMouseEvents=true; panel.hidesOnDeactivate=false; panel.isReleasedWhenClosed=false; panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
    }
    func showMode(english:Bool,near anchor:NSRect) { show(english ? "英" : "中",near:anchor,duration:0.8,badge:true) }
    func show(_ text:String,near anchor:NSRect,duration:TimeInterval=1.6,badge:Bool=false) {
        label.stringValue=text; label.font = badge ? .systemFont(ofSize:14,weight:.semibold) : .systemFont(ofSize:12,weight:.medium)
        let width=badge ? 34 : min(360,ceil(label.intrinsicContentSize.width)+24), size=NSSize(width:width,height:26)
        panel.setContentSize(size); surface.frame=NSRect(origin:.zero,size:size); label.frame=NSRect(x:0,y:(badge ? 4 : 5),width:width,height:18)
        let valid=anchor.height>0, point=valid ? anchor.origin : NSEvent.mouseLocation
        let frame=(NSScreen.screens.first(where:{ valid ? $0.frame.intersects(anchor) : NSMouseInRect(point,$0.frame,false) }) ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin=NSPoint(x:point.x,y:point.y-size.height-4)
        if origin.y<frame.minY { origin.y=(valid ? anchor.maxY : point.y)+4 }
        origin.x=max(frame.minX,min(origin.x,frame.maxX-size.width))
        panel.setFrameOrigin(origin); panel.orderFrontRegardless()
        hiding?.cancel(); let work=DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }; hiding=work
        DispatchQueue.main.asyncAfter(deadline:.now()+duration,execute:work)
    }
}
