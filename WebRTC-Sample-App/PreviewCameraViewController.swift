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
import Photos

class ParentViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupButton()
    }
    
    private func setupButton() {
        let button = UIButton(type: .system)
        button.setTitle("Open Second Controller", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        
        // Add target action
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        
        view.addSubview(button)
        
        // Center the button in the middle of the screen
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 240),
            button.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    @objc private func buttonTapped() {
        let secondController = PreviewCameraViewController()
        secondController.modalPresentationStyle = .overCurrentContext
        present(secondController, animated: true)
    }
}

class PreviewCameraViewController: UIViewController {
    let cameraView = UIView()
    
    let noneButton = UIButton()
    let blurButton = UIButton()
    let imageButton = UIButton()
    
    var selectedImage: UIImage? {
        didSet {
//            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
//                if let image = self?.selectedImage {
//                    self?.cameraManager?.setBackgroundEffect(.image(image: image))
//                }
//            }
        }
    }
    
    var cameraManager: PreviewedCameraManager?
    var previewLayer: AVSampleBufferDisplayLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .white
        setupCloseButton()
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
        cameraManager = PreviewedCameraManager(preset: .vga640x480, frame: 15)
    
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
    
    private func setupCloseButton() {
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        closeButton.backgroundColor = .systemRed
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.layer.cornerRadius = 8
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
        
        view.addSubview(closeButton)
        
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 80),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])
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
    
    private func checkPhotoLibraryPermission() {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            switch status {
            case .authorized, .limited:
                presentPhotoLibrary()
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
                    guard let self else { return }
                    
                    if status == .authorized || status == .limited {
                        self.presentPhotoLibrary()
                    }
                    
                }
            case .denied, .restricted:
                break
            @unknown default:
                break
            }
        }
        
    }
    
    private func presentPhotoLibrary() {
        DispatchQueue.main.async {
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self // Set the delegate to self to receive image picker callbacks
            imagePicker.sourceType = .photoLibrary // Set the source type to photo library (can also be .camera or .savedPhotosAlbum)
            // Present the image picker controller modally
            self.present(imagePicker, animated: true, completion: nil)
        }
        
    }
    
    deinit {
//        cameraManager?.stopCapture()
//        cameraManager = nil
//        previewLayer?.removeFromSuperlayer()
//        previewLayer = nil
    }
    
    @objc private func closeButtonTapped() {
        dismiss(animated: true)
    }
    
    @objc func onBlurTap() {
        cameraManager?.setBackgroundEffect(.blur)
    }

    @objc func onNoneTap() {
        cameraManager?.setBackgroundEffect(nil)
    }
    
    var first: Bool = false
    @objc func onImageTap()  {
//        presentPhotoLibrary()
        checkPhotoLibraryPermission()
        
//        first.toggle()
//        if let image = UIImage(named: "conferenceBackground_\(first ? 1 : 2)"),
//           let imageDataCompress = image.jpegData(compressionQuality: 0),
//           let imageCompress = UIImage(data: imageDataCompress) {
//            cameraManager?.setBackgroundEffect(.image(image: imageCompress))
//        }
    }
    
}


// MARK: - UIImagePickerControllerDelegate
extension PreviewCameraViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        
//        var selectedImage: UIImage?

        if let originalImage = info[.originalImage] as? UIImage {
            cameraManager?.setBackgroundEffect(.image(image: originalImage))
        }
        picker.dismiss(animated: true)
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
