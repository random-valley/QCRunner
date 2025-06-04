//
//  NC01ReferenceCropper.swift
//  QCRunner
//
//  Created by Blake on 03/06/2025.
//

import Foundation
import QIDOScanner
import CoreImage
import Vision
import QIDOTags
import QIDOUtils
import QIDOFrameStream

public struct NC01CompositeReferenceRegionCropper  {
    public func execute(onBaseframe: CIImage) throws -> CIImage {

        let refExtent = onBaseframe.extent

        var leftRefRegion = CGRect(
            x: refExtent.width * 0.16,
            y: refExtent.height * 0.4,
            width: refExtent.width * 0.1,
            height: refExtent.height * 0.3)

        leftRefRegion = leftRefRegion.insetBy(dx: leftRefRegion.width * 0.1, dy: 0)

        var rightRefRegion = CGRect(
            x: refExtent.width * 0.75,
            y: refExtent.height * 0.4,
            width: refExtent.width * 0.1,
            height: refExtent.height * 0.3)

        rightRefRegion = rightRefRegion.insetBy(dx: rightRefRegion.width * 0.1, dy: 0)

        let tp = onBaseframe.cropped(to: leftRefRegion).translateImageOriginToWorldOrigin()
        let bp = onBaseframe.cropped(to: rightRefRegion).translateImageOriginToWorldOrigin()

        let compFilter = CIFilter.sourceOverCompositing()
        compFilter.inputImage = tp
        compFilter.backgroundImage = bp.transformed(by: .init(translationX: tp.extent.width - 1, y: 0))

        guard let out = compFilter.outputImage?.translateImageOriginToWorldOrigin() else {
            fatalError()
        }

        return out
    }
}


public class NC01PatchCropOperation  {
    var barcodeAnchorX: Double
    var barcodeAnchorY: Double
    var xDirection: FloatingPointSign
    var yDirection: FloatingPointSign
    var xRatio: Double
    var yRatio: Double
    var widthInset: CGFloat
    var heightInset: CGFloat

    public init(barcodeAnchorX: Double, barcodeAnchorY: Double, xDirection: FloatingPointSign, yDirection: FloatingPointSign, xRatio: Double, yRatio: Double, widthInset: Float, heightInset: Float) {
        self.barcodeAnchorX = barcodeAnchorX
        self.barcodeAnchorY = barcodeAnchorY
        self.xDirection = xDirection
        self.yDirection = yDirection
        self.xRatio = xRatio
        self.yRatio = yRatio
        // Below are flipped, due to toSize declaration in TagDesignDescription flipping x and y.
        self.widthInset = CGFloat(heightInset)
        self.heightInset = CGFloat(widthInset)
    }

    public func execute(onBaseframeRegion baseframe: CIImage) throws -> CIImage {
        let capturedBaseframeWidth = baseframe.extent.width
        let capturedBaseframeHeight = baseframe.extent.height

        let outputSearchWidth = xRatio*capturedBaseframeWidth
        let outputSearchHeight = (1 - yRatio)*capturedBaseframeHeight
        // grab rectangle equivalent to "search frame"

        let outputRect = CGRect.init(x: barcodeAnchorX*capturedBaseframeWidth, y: yRatio*outputSearchHeight, width: capturedBaseframeWidth - barcodeAnchorX*capturedBaseframeWidth, height: yRatio*outputSearchHeight)
        // Below for converting above rectangle into just patch rectangle
        let dx = (outputRect.width * (1 - widthInset)) / 2
        let dy = (outputRect.height * (1 - heightInset)) / 2
        let cropAmount = outputRect.insetBy(dx: ceil(dx), dy: ceil(dy))

        let crop = baseframe.cropped(to: cropAmount)
            .settingAlphaOne(in: cropAmount)
            .premultiplyingAlpha()
            .translateImageOriginToWorldOrigin()

        return crop
    }

}


public class DataMatrixBarcodeCroppingOperation {
    let dataMatrixOrientation: TagPositionRuleSetOrientation
    let payloadSearchString: String
    let logger: Logger

    public init(tag: TagDesignDescription, logger: Logger, dataMatrixOrientation: TagPositionRuleSetOrientation, payloadSearchString: String) {
        self.dataMatrixOrientation = dataMatrixOrientation
        self.payloadSearchString = payloadSearchString
        self.logger = logger
    }
    
    public func execute(on img: CIImage) async throws -> CIImage {
        return try await withCheckedThrowingContinuation({ continuation in
            do {
                
                let imageRequestHandler = VNImageRequestHandler(ciImage: img, orientation: .left, options: [:])
                
                let detectionRequest = VNDetectBarcodesRequest(completionHandler: { [weak self] (request, error) in
                    guard let self = self else { return }
                    guard error == nil else { return continuation.resume(throwing: error!) } 
                    self.handleVisionDetectionRequest(request, sourceImage: img, continuation: continuation)
                })
                
                #if targetEnvironment(simulator)
                    if #available(iOS 17.0, *) {
                      let allDevices = MLComputeDevice.allComputeDevices

                      for device in allDevices {
                        if(device.description.contains("MLCPUComputeDevice")){
                          detectionRequest.setComputeDevice(.some(device), for: .main)
                          break
                        }
                      }

                    } else {
                      // Fallback on earlier versions
                        detectionRequest.usesCPUOnly = true
                    }
                #endif
                
                detectionRequest.symbologies = [.dataMatrix, .qr, .microQR]
                try imageRequestHandler.perform([detectionRequest])

            } catch {
                continuation.resume(throwing: error)
            }
        })
    }

    fileprivate func handleVisionDetectionRequest(_ request: VNRequest, sourceImage: CIImage, continuation: CheckedContinuation<CIImage, Error>) {
        do {

            let i = request.results
            let dataMatrix = request.results?
                .compactMap({ $0 as? VNBarcodeObservation})
                .filter({ $0.confidence == 1.0 })
                .filter({ ($0.payloadStringValue ?? "").contains(payloadSearchString) })
                .first

            guard let dataMatrix = dataMatrix else { throw Errors.NoQRCodeDetectedInSourceImage }

            let corners = [dataMatrix.bottomLeft, dataMatrix.topLeft, dataMatrix.topRight, dataMatrix.bottomRight].map({
                VNImagePointForNormalizedPoint($0, Int(sourceImage.oriented(.left).extent.width), Int(sourceImage.oriented(.left).extent.height))
            })

            let detection = orderBarcodeCorners(corners)

            guard let pc = CIFilter(name: "CIPerspectiveCorrection") else { throw GraphicsErrors.CIFilterInitialisationError }
            pc.setValuesForKeys(["inputTopLeft": CIVector(cgPoint: detection.topLeft),
                                 "inputTopRight": CIVector(cgPoint: detection.topRight),
                                 "inputBottomRight": CIVector(cgPoint: detection.bottomRight),
                                 "inputBottomLeft": CIVector(cgPoint: detection.bottomLeft),
                                 "inputCrop": NSNumber(booleanLiteral: true),
                                 "inputImage": sourceImage.oriented(.left)])

            guard let output = pc.outputImage else { throw Errors.CIFilterOutputUnwrappingError }
            return continuation.resume(returning: output)
        } catch {
            return continuation.resume(throwing: error)
        }
    }

    fileprivate func orderBarcodeCorners(_ corners: [CGPoint]) -> DetectedBarcodeObservation {
        switch self.dataMatrixOrientation {
        case .upright, .rotatedClockwise, .rotatedCounterClockwise:
            return DetectedBarcodeObservation(bottomLeft: corners[0], topLeft: corners[1], topRight: corners[2], bottomRight: corners[3])
        case .upsideDown:
            return DetectedBarcodeObservation(bottomLeft: corners[2], topLeft: corners[3], topRight: corners[0], bottomRight: corners[1])
        }
    }
}

struct DetectedBarcodeObservation {
    var bottomLeft: CGPoint
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
}


enum Errors: Swift.Error {
    case CIFilterOutputUnwrappingError
    case NoQRCodeDetectedInSourceImage
}
