#!/usr/bin/env python3
"""Compile the exact pure production helper; pin all three UIKit call sites."""
import pathlib, subprocess, tempfile, shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=ROOT/'src/ios/Views/Chat/Markdown/Attachments/ImageAttachment.swift'
s=p.read_text()
a=s.index('enum ImageAttachmentGeometry {'); b=s.index('\nfinal class ImageAttachment:',a)
helper=s[a:b]
assert s.count('return ImageAttachmentGeometry.bounds(')==2
assert 'ImageAttachmentGeometry.bounds(img.size, availableWidth: width' in s
assert 'ImageAttachmentGeometry.bounds(knownSize, availableWidth: width' in s
assert 'ImageAttachmentGeometry.imageSize(img.size, availableWidth: width' in s
assert 'imageView.frame = shadowView.bounds' in s
assert 'imageView.backgroundColor = .black' not in s
assert 'imageView.contentMode = .scaleAspectFit' in s
assert 'width: imgWidth, height: h), cornerRadius: 8' in s
assert 'makeView(width: boundingRect.width)' in (ROOT/'src/ios/Views/Chat/Markdown/TextKit/SelectableMarkdownTextView+AttachmentViews.swift').read_text()
swift=r'''
var checks = 0
func check(_ value: Bool, _ label: String) { checks += 1; if !value { fatalError(label) } }
let sizes: [CGSize] = [CGSize(width:1200,height:600),CGSize(width:1000,height:1000),CGSize(width:600,height:1800),CGSize(width:10,height:100000),CGSize(width:10,height:10),CGSize(width:1,height:1),CGSize(width:0,height:30),CGSize(width: -1,height:30),CGSize(width:CGFloat.nan,height:10),CGSize(width:10,height:CGFloat.infinity)]
let widths: [CGFloat] = [20,52,180,329.833,388,400,10000000,.nan,.infinity]
let caps: [CGFloat] = [40,200,422,.nan,0]
for (index, size) in sizes.enumerated() {
    for width in widths {
        for cap in caps {
            let display = ImageAttachmentGeometry.imageSize(size, availableWidth:width, maxHeight:cap)
            let box = ImageAttachmentGeometry.bounds(size,availableWidth:width,maxHeight:cap)
            check(display.width.isFinite && display.height.isFinite && display.width > 0 && display.height > 0, "finite \(index)")
            check(display.width <= 388.001 && display.height <= (cap.isFinite && cap > 0 ? cap : 40)+0.001, "caps")
            let valid = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            let ratio: CGFloat = valid ? size.width/size.height : 1
            check(abs(display.width/display.height-ratio) < max(0.000001,ratio*0.000001), "aspect")
            check(abs(box.width-display.width-12)<0.00001 && abs(box.height-display.height-12)<0.00001,"shadow")
            // makeImageView receives the ALREADY-MEASURED attachment width.
            let actual = ImageAttachmentGeometry.imageSize(size, availableWidth:box.width,maxHeight:cap)
            check(abs(actual.width-display.width)<0.00001 && abs(actual.height-display.height)<0.00001,"measured -> actual idempotent")
        }
    }
}
let long = ImageAttachmentGeometry.imageSize(CGSize(width:600,height:6000),availableWidth:360,maxHeight:422)
check(abs(long.width-42.2)<0.00001 && abs(long.height-422)<0.00001,"reported black border geometry")
print("IMAGE_GEOMETRY_PASS checks=\(checks) wiring=9")
'''
with tempfile.TemporaryDirectory() as d:
    source=pathlib.Path(d)/'main.swift'; source.write_text('import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n'+helper+swift)
    binary=pathlib.Path(d)/'geometry'
    subprocess.run([shutil.which('swiftc') or 'swiftc',str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
