//
//  PreviewCameraViewController.swift
//  WebRTCiOSSDK
//
//  Created by Socheat on 29/5/25.
//

import Foundation
import AVFoundation
import UIKit
import WebRTCiOSSDK

class PreviewCameraViewController: UIViewController {
    let cameraView = UIView()
    
    let noneButton = UIButton()
    let blurButton = UIButton()
    let imageButton = UIButton()
    
    var cameraManager: PreviewedCameraManager?
    var previewLayer: AVSampleBufferDisplayLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupCameraView()
        setupButton()
    }
    
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        
        setupCameraManager()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        cameraManager?.stopCapture()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = cameraView.bounds
    }
    
    private func setupCameraManager() {
        cameraManager = PreviewedCameraManager()
    
        previewLayer = cameraManager!.getPreviewLayer()
        previewLayer?.bounds = view.bounds
        cameraView.layer.addSublayer(previewLayer!)
        
        cameraManager?.startCapture()
    }
    
    private func setupCameraView() {
        cameraView.layer.cornerRadius = 10
        cameraView.clipsToBounds = true
        view.addSubview(cameraView)
        
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        cameraView.widthAnchor.constraint(equalToConstant: 150).isActive = true
        cameraView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        cameraView.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        cameraView.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
    }
    
    private func setupButton() {
        let stack = UIStackView(arrangedSubviews: [noneButton, imageButton, blurButton])
        stack.axis = .horizontal
        
        imageButton.setTitle("Image", for: .normal)
        blurButton.setTitle("Blur", for: .normal)
        noneButton.setTitle("None", for: .normal)
        
        imageButton.setTitleColor(.systemBlue, for: .normal)
        blurButton.setTitleColor(.systemBlue, for: .normal)
        noneButton.setTitleColor(.systemBlue, for: .normal)
        
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor).isActive = true
        stack.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        stack.heightAnchor.constraint(equalToConstant: 40).isActive = true
        
        [noneButton, imageButton, blurButton].forEach {
            $0.widthAnchor.constraint(equalToConstant: 80).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 80).isActive = true
        }
        
        blurButton.addTarget(self, action: #selector(onBlurTap), for: .touchUpInside)
        imageButton.addTarget(self, action: #selector(onImageTap), for: .touchUpInside)
        noneButton.addTarget(self, action: #selector(onNoneTap), for: .touchUpInside)
    }
    
    deinit {
        cameraManager?.stopCapture()
        cameraManager = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }
    
    @objc func onBlurTap() {
        cameraManager?.setBackgroundEffect(.blur)
    }

    @objc func onNoneTap() {
        cameraManager?.setBackgroundEffect(nil)
    }
    
    @objc func onImageTap()  {
        if let image = UIImage(named: "conferenceBackground") {
            cameraManager?.setBackgroundEffect(.image(image: image))
        }
    }
    
}

