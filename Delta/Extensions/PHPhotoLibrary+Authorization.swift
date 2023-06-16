//
//  PHPhotoLibrary+Authorization.swift
//  Delta
//
//  Created by Chris Rittenhouse on 4/24/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import UIKit
import Photos

extension PHPhotoLibrary
{
    static func runIfAuthorized(code: @escaping () -> Void)
    {
        PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: { success in
            switch success
            {
            case .authorized, .limited:
                code()
                
            case .denied, .restricted, .notDetermined: break
            @unknown default: break
            }
        })
    }
    
    static func saveImageData(_ data: Data)
    {
        // Save the image to the Photos app
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }, completionHandler: { success, error in
            if success
            {
                // Image saved successfully
                print("Image saved to Photos app.")
            }
            else
            {
                // Error saving image
                print("Error saving image: \(error?.localizedDescription ?? "Unknown error")")
            }
        })
    }
}
