//
//  SwiftInjection.swift
//  InjectionBundle
//
//  Created by John Holdsworth on 05/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/ResidentEval/InjectionBundle/SwiftInjection.swift#15 $
//
//  Cut-down version of code injection in Swift. Uses code
//  from SwiftEval.swift to recompile and reload class.
//

#if arch(x86_64) // simulator/macOS only
import Foundation

@objc public protocol SwiftInjected {
    @objc optional func injected()
}

#if os(iOS) || os(tvOS)
import UIKit

extension UIViewController {

    /// inject a UIView controller and redraw
    public func injectVC() {
        inject()
        for subview in self.view.subviews {
            subview.removeFromSuperview()
        }
        if let sublayers = self.view.layer.sublayers {
            for sublayer in sublayers {
                sublayer.removeFromSuperlayer()
            }
        }
        viewDidLoad()
    }
}
#else
import Cocoa
#endif

extension NSObject {

    public func inject() {
        if let oldClass: AnyClass = object_getClass(self) {
            SwiftInjection.inject(oldClass: oldClass, classNameOrFile: "\(oldClass)")
        }
    }

    @objc
    public class func inject(file: String) {
        let path = URL(fileURLWithPath: file).deletingPathExtension().path
        SwiftInjection.inject(oldClass: nil, classNameOrFile: String(path.dropFirst()))
    }
}

public class SwiftInjection {

    static func inject(oldClass: AnyClass?, classNameOrFile: String) {
        if let newClasses = SwiftEval.instance.rebuildClass(oldClass: oldClass, classNameOrFile: classNameOrFile, extra: nil) {
            let oldClasses = //oldClass != nil ? [oldClass!] :
                newClasses.map { objc_getClass(class_getName($0)) as! AnyClass }
            for i in 0..<oldClasses.count {
                let oldClass: AnyClass = oldClasses[i], newClass: AnyClass = newClasses[i]

                // old-school swizzle Objective-C class & instance methods
                injection(swizzle: object_getClass(newClass), onto: object_getClass(oldClass))
                injection(swizzle: newClass, onto: oldClass)

                // overwrite Swift vtable of existing class with implementations from new class
                let existingClass = unsafeBitCast(oldClass, to: UnsafeMutablePointer<ClassMetadataSwift>.self)
                let classMetadata = unsafeBitCast(newClass, to: UnsafeMutablePointer<ClassMetadataSwift>.self)

                // Swift equivalent of Swizzling
                if (classMetadata.pointee.Data & 0x1) == 1 {
                    if classMetadata.pointee.ClassSize != existingClass.pointee.ClassSize {
                        NSLog("\(oldClass) metadata size changed. Did you add a method?")
                    }

                    func byteAddr<T>(_ location: UnsafeMutablePointer<T>) -> UnsafeMutablePointer<UInt8> {
                        return location.withMemoryRebound(to: UInt8.self, capacity: 1) { $0 }
                    }

                    let vtableOffset = byteAddr(&existingClass.pointee.IVarDestroyer) - byteAddr(existingClass)
                    let vtableLength = Int(existingClass.pointee.ClassSize -
                        existingClass.pointee.ClassAddressPoint) - vtableOffset

                    print("Injected '\(NSStringFromClass(oldClass))', vtable length: \(vtableLength)")
                    memcpy(byteAddr(existingClass) + vtableOffset,
                           byteAddr(classMetadata) + vtableOffset, vtableLength)
                }

                // implement -injected() method using sweep of objects in application
                if class_getInstanceMethod(oldClass, #selector(SwiftInjected.injected)) != nil {
                    #if os(iOS) || os(tvOS)
                    let app = UIApplication.shared
                    #else
                    let app = NSApplication.shared
                    #endif
                    let seeds: [Any] =  [app.delegate as Any] + app.windows
                    sweepValue(seeds, for: oldClass)
                    seen.removeAll()
                }
            }

            let notification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")
            NotificationCenter.default.post(name: notification, object: oldClasses)
        }
    }

    static func injection(swizzle newClass: AnyClass?, onto oldClass: AnyClass?) {
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(newClass, &methodCount) {
            for i in 0 ..< Int(methodCount) {
                class_replaceMethod(oldClass, method_getName(methods[i]),
                                    method_getImplementation(methods[i]),
                                    method_getTypeEncoding(methods[i]))
            }
            free(methods)
        }
    }

    static func sweepValue(_ value: Any, for targetClass: AnyClass) {
        let mirror = Mirror(reflecting: value)
        if var style = mirror.displayStyle {
            if _typeName(mirror.subjectType).hasPrefix("Swift.ImplicitlyUnwrappedOptional<") {
                style = .optional
            }
            switch style {
            case .set:
                fallthrough
            case .collection:
                for (_, child) in mirror.children {
                    sweepValue(child, for: targetClass)
                }
                return
            case .dictionary:
                for (_, child) in mirror.children {
                    for (_, element) in Mirror(reflecting: child).children {
                        sweepValue(element, for: targetClass)
                    }
                }
                return
            case .class:
                sweepInstance(value as AnyObject, for: targetClass)
                return
            case .optional:
                if let some = mirror.children.first?.value {
                    sweepValue(some, for: targetClass)
                }
                return
            default:
                break
            }
        }

        if let style = mirror.displayStyle {
            switch style {
            case .enum:
                if let evals = mirror.children.first?.value {
                    sweepValue(evals, for: targetClass)
                }
            case .tuple:
                sweepMembers(value, for: targetClass)
            case .struct:
                sweepMembers(value, for: targetClass)
            default:
                break
            }
        }
    }

    static var seen = [UnsafeRawPointer: Bool]()

    static func sweepInstance(_ instance: AnyObject, for targetClass: AnyClass) {
        let reference = unsafeBitCast(instance, to: UnsafeRawPointer.self)
        if seen[reference] == nil {
            seen[reference] = true

            if object_getClass(instance) == targetClass {
                let proto = unsafeBitCast(instance, to: SwiftInjected.self)
                proto.injected?()
            }

            sweepMembers(instance, for: targetClass)
            instance.legacySweep?(for: targetClass)
        }
    }

    static func sweepMembers(_ instance: Any, for targetClass: AnyClass) {
        var mirror: Mirror? = Mirror(reflecting: instance)
        while mirror != nil {
            for (_, value) in mirror!.children {
                sweepValue(value, for: targetClass)
            }
            mirror = mirror!.superclassMirror
        }
    }
}

extension NSObject {
    @objc func legacySweep(for targetClass: AnyClass) {
        var icnt: UInt32 = 0, cls: AnyClass? = object_getClass(self)!
        let object = "@".utf16.first!
        while cls != nil && cls != NSObject.self && cls != NSURL.self {
            #if os(OSX)
            let className = NSStringFromClass(cls!)
            if cls != NSWindow.self && className.starts(with: "NS") {
                return
            }
            #endif
            if let ivars = class_copyIvarList(cls, &icnt) {
                for i in 0 ..< Int(icnt) {
                    if let type = ivar_getTypeEncoding(ivars[i]), type[0] == object {
                        (unsafeBitCast(self, to: UnsafePointer<Int8>.self) + ivar_getOffset(ivars[i]))
                            .withMemoryRebound(to: AnyObject?.self, capacity: 1) {
                                if let obj = $0.pointee {
                                    SwiftInjection.sweepInstance(obj, for: targetClass)
                                }
                        }
                    }
                }
                free(ivars)
            }
            cls = class_getSuperclass(cls)
        }
    }
}

extension NSArray {
    @objc override func legacySweep(for targetClass: AnyClass) {
        self.forEach { SwiftInjection.sweepInstance($0 as AnyObject, for: targetClass) }
    }
}

extension NSDictionary {
    @objc override func legacySweep(for targetClass: AnyClass) {
        self.allValues.forEach { SwiftInjection.sweepInstance($0 as AnyObject, for: targetClass) }
    }
}

/**
 Layout of a class instance. Needs to be kept in sync with ~swift/include/swift/Runtime/Metadata.h
 */
public struct ClassMetadataSwift {

    public let MetaClass: uintptr_t = 0, SuperClass: uintptr_t = 0
    public let CacheData1: uintptr_t = 0, CacheData2: uintptr_t = 0

    public let Data: uintptr_t = 0

    /// Swift-specific class flags.
    public let Flags: UInt32 = 0

    /// The address point of instances of this type.
    public let InstanceAddressPoint: UInt32 = 0

    /// The required size of instances of this type.
    /// 'InstanceAddressPoint' bytes go before the address point;
    /// 'InstanceSize - InstanceAddressPoint' bytes go after it.
    public let InstanceSize: UInt32 = 0

    /// The alignment mask of the address point of instances of this type.
    public let InstanceAlignMask: UInt16 = 0

    /// Reserved for runtime use.
    public let Reserved: UInt16 = 0

    /// The total size of the class object, including prefix and suffix
    /// extents.
    public let ClassSize: UInt32 = 0

    /// The offset of the address point within the class object.
    public let ClassAddressPoint: UInt32 = 0

    /// An out-of-line Swift-specific description of the type, or null
    /// if this is an artificial subclass.  We currently provide no
    /// supported mechanism for making a non-artificial subclass
    /// dynamically.
    public let Description: uintptr_t = 0

    /// A function for destroying instance variables, used to clean up
    /// after an early return from a constructor.
    public var IVarDestroyer: SIMP? = nil

    // After this come the class members, laid out as follows:
    //   - class members for the superclass (recursively)
    //   - metadata reference for the parent, if applicable
    //   - generic parameters for this class
    //   - class variables (if we choose to support these)
    //   - "tabulated" virtual methods

}

/** pointer to a function implementing a Swift method */
public typealias SIMP = @convention(c) (_: AnyObject) -> Void
#endif
