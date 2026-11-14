"""Generate an actual UIKit reflow fixture from exact production image branches.
Only image loading/gesture/logging are shimmed; the bitmap is already loaded.
Creation, stale detection and overlay reuse execute production source verbatim.
"""
def source(root):
    p=root/'src/ios/Views/Chat/Markdown'
    image=(p/'Attachments/ImageAttachment.swift').read_text()
    views=(p/'TextKit/SelectableMarkdownTextView+AttachmentViews.swift').read_text()
    geometry=image[image.index('enum ImageAttachmentGeometry {'):image.index('\nfinal class ImageAttachment:')]
    creation=image[image.index('    private func makeImageView('):image.index('    private func makePlaceholderView(')]
    start=views.index('                if let imageAttach = attachment as? ImageAttachment {')
    branch=views[start:views.index('                } else if let videoAttach',start)]+'                }\n'
    assert 'abs(existingView.bounds.width - boundingRect.width) > 0.5' in branch
    assert 'abs(existingView.bounds.height - boundingRect.height) > 0.5' in branch
    reuse_start=views.index('                reusedIds.insert(attachId)')
    reuse=views[reuse_start:views.index('            } else if let codeBlock',reuse_start)]
    assert 'size: view.frame.size' in reuse
    return geometry+r'''
private struct AppLogger { init(category: String) {} ; func info(_ text: String) {} }
private final class ImageTapGesture: UITapGestureRecognizer {
    var attachedImage: UIImage?; var sourceURL = ""; var messageId: UUID?
    @objc func handleTap() {}
}
// The asynchronous loader is irrelevant: this fixture starts already loaded.
private final class ImageAttachment: NSObject {
    static let imageShadowInset = ImageAttachmentGeometry.shadowInset
    let source = "fixture://loaded"; let messageId: UUID? = nil
    var needsViewRebuild = false; var onLoad: (() -> Void)?
    let loadedImage: UIImage?
    init(image: UIImage) { loadedImage = image }
    static func shortSrc(_ value: String) -> String { value }
    func beginLoadingIfNeeded() {}
    func makeView(width: CGFloat) -> UIView { makeImageView(loadedImage!, width: width) }
'''+creation+r'''
}
private final class ImageReflowHarness {
    func refreshAttachmentViews() {}
    func update(_ attachment: NSObject, existingView: UIView, boundingRect: CGRect) -> UIView {
        let attachId = ObjectIdentifier(attachment)
        var reusedIds = Set<ObjectIdentifier>()
        let inlineOrigin: CGPoint? = nil
        let view: UIView
        var stale = false
'''+branch+r'''
        if stale, let imageAttach = attachment as? ImageAttachment {
            existingView.removeFromSuperview()
            view = imageAttach.makeView(width: boundingRect.width)
        } else { view = existingView }
'''+reuse+r'''
        return view
    }
}
enum ImageReflowFixture {
    static func run(check: (Bool, String) -> Void) {
        var checks = 0
        func require(_ ok: Bool, _ label: String) { checks += 1; check(ok, "image reflow: "+label) }
        for size in [CGSize(width:1200,height:600),CGSize(width:600,height:6000),CGSize(width:1200,height:80)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let bitmap = UIGraphicsImageRenderer(size:size,format:format).image { c in UIColor.blue.setFill(); c.fill(CGRect(origin:.zero,size:size)) }
            let attachment = ImageAttachment(image:bitmap), identity = ObjectIdentifier(attachment)
            let harness = ImageReflowHarness()
            var old = attachment.makeView(width:400)
            for width: CGFloat in [360,180,320] {
                let box = ImageAttachmentGeometry.bounds(size,availableWidth:width,maxHeight:UIScreen.main.bounds.height/2)
                let shouldChange = abs(old.bounds.width-box.width)>0.5 || abs(old.bounds.height-box.height)>0.5
                let view = harness.update(attachment,existingView:old,boundingRect:box)
                require(ObjectIdentifier(attachment)==identity,"same attachment identity")
                require((view !== old)==shouldChange,"only mismatched overlay rebuilt")
                require(abs(view.bounds.width-box.width)<0.001 && abs(view.bounds.height-box.height)<0.001,"TextKit box equals actual container")
                let shadow = view.subviews[0], image = shadow.subviews[0] as! UIImageView
                require(shadow.frame.origin==CGPoint(x:6,y:6),"shadow inset")
                require(abs(shadow.bounds.width+12-box.width)<0.001 && abs(shadow.bounds.height+12-box.height)<0.001,"shadow size")
                require(image.frame==shadow.bounds,"bitmap fills shadow wrapper")
                require(shadow.layer.shadowPath!.boundingBoxOfPath==shadow.bounds,"shadow path follows resized image")
                require(abs(image.bounds.width/image.bounds.height-size.width/size.height)<0.00001,"aspect preserved")
                require(harness.update(attachment,existingView:view,boundingRect:box) === view,"stable geometry really reused")
                require(image.image === bitmap,"same decoded bitmap")
                old = view
            }
        }
        print("IMAGE_REFLOW_UIKIT_PASS checks=\(checks) cases=9 exact_creation=1 exact_reuse=1")
    }
}
'''
