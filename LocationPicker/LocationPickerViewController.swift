//
//  LocationPickerViewController.swift
//  LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Copyright (c) 2015 almassapargali. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation
import SystemConfiguration
import CoreImage.CIFilterBuiltins
import QuartzCore

open class LocationPickerViewController: UIViewController {
    struct CurrentLocationListener {
        let once: Bool
        let action: (CLLocation) -> ()
    }
    
    public var completion: ((Location?) -> ())?
    
    // region distance to be used for creation region when user selects place from search results
    public var resultRegionDistance: CLLocationDistance = 600
    
    /// default: true
    public var showCurrentLocationButton = true
    
    /// default: true
    public var showCurrentLocationInitially = true
    
    /// default: false
    /// Select current location only if `location` property is nil.
    public var selectCurrentLocationInitially = true
    
    /// see `region` property of `MKLocalSearchRequest`
    /// default: false
    public var useCurrentLocationAsHint = false
    
    /// default: "Search or enter an address"
    public var searchBarPlaceholder = "Search or enter an address"
    
    /// default: "Search History"
    public var searchHistoryLabel = "Search History"
    
    /// default: "Select"
    public var selectButtonTitle = "Select"
    
    /// default: "Error" and "There seems to be no connection to the Internet."
    public var noInternetConnectionErrorTitle = "Error"
    public var noInternetConnectionErrorMessage = "There seems to be no connection to the Internet."
    
    /// default: "OK"
    public var okButtonTitle = "OK"
    
    public lazy var currentLocationButtonBackground: UIColor = {
        if let navigationBar = self.navigationController?.navigationBar,
           let barTintColor = navigationBar.barTintColor {
            return barTintColor
        } else { return .white }
    }()
    
    /// default: .minimal
    public var searchBarStyle: UISearchBar.Style = .minimal
    
    /// default: .default
    public var statusBarStyle: UIStatusBarStyle = .default
    
    open override var preferredStatusBarStyle : UIStatusBarStyle {
        return self.statusBarStyle
    }
    
    var presentedInitialLocation = false
    
    @available(iOS 13.0, *)
    public lazy var searchTextFieldColor: UIColor = .clear
    
    public var mapType: MKMapType = .hybrid {
        didSet {
            if isViewLoaded {
                self.mapView.mapType = self.mapType
            }
        }
    }
    
    public var location: Location? {
        didSet {
            if isViewLoaded {
                self.searchBar.text = self.location.flatMap({ $0.title }) ?? ""
                self.updateAnnotation()
            }
        }
    }
    
    private var isConnectedToNetwork: Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)
        
        guard let defaultRouteReachability = withUnsafePointer(
            to: &zeroAddress, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    SCNetworkReachabilityCreateWithAddress(nil, $0)
                }
            })
        else {
            return false
        }
        
        var flags: SCNetworkReachabilityFlags = []
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) {
            return false
        }
        
        if flags.isEmpty {
            return false
        }
        
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        
        return (isReachable && !needsConnection)
    }
    
    static let SearchTermKey = "SearchTermKey"
    
    let historyManager = SearchHistoryManager()
    let locationManager = CLLocationManager()
    let geocoder = CLGeocoder()
    var localSearch: MKLocalSearch?
    var searchTimer: Timer?
    
    var currentLocationListeners: [CurrentLocationListener] = []
    
    var mapView: MKMapView!
    
    lazy var results: LocationSearchResultsViewController = {
        let results = LocationSearchResultsViewController()
        results.onSelectLocation = { [weak self] in self?.selectedLocation($0) }
        results.searchHistoryLabel = self.searchHistoryLabel
        return results
    }()
    
    lazy var searchController: UISearchController = {
        let search = UISearchController(searchResultsController: self.results)
        search.searchResultsUpdater = self
        search.hidesNavigationBarDuringPresentation = false
        return search
    }()
    
    lazy var searchBar: UISearchBar = {
        let searchBar = self.searchController.searchBar
        searchBar.searchBarStyle = self.searchBarStyle
        searchBar.placeholder = self.searchBarPlaceholder
        if #available(iOS 13.0, *) {
            searchBar.searchTextField.backgroundColor = self.searchTextFieldColor
        }
        return searchBar
    }()
    
    lazy var topBlurView: UIView = {
        return VariableBlurUIView(
            maxBlurRadius: 5,
            direction: .blurredTopClearBottom)
    }()
    
    lazy var selectLocationButton: UIButton = {
        let selectLocationButton = UIButton(type: .system)
        selectLocationButton.isHidden = self.location == nil
        if #available(iOS 15.0, *) {
            var configuration: UIButton.Configuration = {
                if #available(iOS 26.0, macOS 26.0, *) {
                    return .prominentGlass()
                } else {
                    return .filled()
                }
            }()
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .large
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = .tintColor
            configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
                return outgoing
            }
            
            selectLocationButton.configuration = configuration
            
        } else {
            selectLocationButton.backgroundColor = .systemBlue
            selectLocationButton.layer.cornerRadius = 14
            selectLocationButton.layer.masksToBounds = true
            
            selectLocationButton.titleLabel?.font = UIFont.systemFont(
                ofSize: 17,
                weight: .semibold)
            selectLocationButton.setTitleColor(.white, for: UIControl.State())
        }
        
        selectLocationButton.setTitle(self.selectButtonTitle, for: UIControl.State())
        selectLocationButton.addTarget(
            self,
            action: #selector(self.selectLocationButtonClicked),
            for: .touchUpInside)
        
        return selectLocationButton
    }()
    
    private var topBlurViewHeightConstraint: NSLayoutConstraint!
    
    open override func loadView() {
        
        // Map View
        self.mapView = MKMapView(frame: UIScreen.main.bounds)
        self.mapView.mapType = self.mapType
        self.view = self.mapView
        
        // Top Blur View
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            self.view.addSubview(self.topBlurView)
            
            self.topBlurView.translatesAutoresizingMaskIntoConstraints = false
            self.topBlurViewHeightConstraint = self.topBlurView.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                self.topBlurViewHeightConstraint,
                self.topBlurView.topAnchor.constraint(equalTo: self.view.topAnchor),
                self.topBlurView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                self.topBlurView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
            ])
        }
        
        // Select Location Button
        self.view.addSubview(self.selectLocationButton)
        self.selectLocationButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.selectLocationButton.heightAnchor.constraint(equalToConstant: 50),
            self.selectLocationButton.bottomAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -50),
            self.selectLocationButton.leadingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 30),
            self.selectLocationButton.trailingAnchor.constraint(
                equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -30)
        ])
        
        self.locationManagerDidChangeAuthorization(self.locationManager)
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        if #available(iOS 13.0, *), let navigationController = navigationController {
            let appearance = navigationController.navigationBar.standardAppearance
            appearance.backgroundColor = navigationController.navigationBar.barTintColor
            self.navigationItem.standardAppearance = appearance
            self.navigationItem.scrollEdgeAppearance = appearance
        }
        
        self.locationManager.delegate = self
        self.mapView.delegate = self
        self.searchBar.delegate = self
        
        // gesture recognizer for adding by tap
        let locationSelectGesture = UILongPressGestureRecognizer(
            target: self, action: #selector(self.addLocation))
        locationSelectGesture.delegate = self
        self.mapView.addGestureRecognizer(locationSelectGesture)
        
        // search
        if #available(iOS 11.0, *) {
            self.navigationItem.searchController = self.searchController
        } else {
            self.navigationItem.titleView = self.searchBar
            // http://stackoverflow.com/questions/32675001/uisearchcontroller-warning-attempting-to-load-the-view-of-a-view-controller/
            _ = self.searchController.view
        }
        self.definesPresentationContext = true
        
        // user location
        self.mapView.userTrackingMode = .none
        self.mapView.showsUserLocation = self.showCurrentLocationInitially || self.showCurrentLocationButton
        
        if useCurrentLocationAsHint {
            self.getCurrentLocation()
        }
        
        // Update the UI in order to always show the search bar with full width.
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, *) {
            self.navigationController?.navigationBar.traitOverrides.horizontalSizeClass = .compact
        }
        
        // Update the search bar placement.
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            self.navigationItem.preferredSearchBarPlacement = .integrated
            self.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
        }
    }
    
    open override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        // Remove all delegates.
        self.locationManager.delegate = nil
        self.mapView.delegate = nil
        self.searchBar.delegate = nil
        self.searchController.delegate = nil
        self.searchController.searchResultsUpdater = nil
        
        // Remove all gesture recognizers.
        if let recognizers = self.mapView?.gestureRecognizers {
            for recognizer in recognizers {
                recognizer.delegate = nil
                self.mapView.removeGestureRecognizer(recognizer)
            }
        }
        
        // Remove the map view.
        self.mapView.mapType = .standard
        self.mapView.showsUserLocation = false
        self.mapView.layer.removeAllAnimations()
        self.mapView.removeAnnotations(self.mapView.annotations)
        self.mapView.removeOverlays(self.mapView.overlays)
        self.mapView.removeFromSuperview()
        self.mapView = nil
        
        // Cancel all timers and events.
        self.searchTimer?.invalidate()
        self.localSearch?.cancel()
        self.geocoder.cancelGeocode()
        
        // Cleanup all other variables.
        self.completion = nil
        self.results.onSelectLocation = nil
        self.currentLocationListeners.removeAll()
    }
    
    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // setting initial location here since viewWillAppear is too early, and viewDidAppear is too late
        if !self.presentedInitialLocation {
            self.setInitialLocation()
            self.presentedInitialLocation = true
        }
        
        // Update the height of the top blur view.
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            if let navBar = self.navigationController?.navigationBar {
                let navBarFrameInView = navBar.convert(navBar.bounds, to: self.view)
                self.topBlurViewHeightConstraint.constant = navBarFrameInView.maxY + 50
            }
        }
        
        #if targetEnvironment(macCatalyst)
        if let imageView = self.searchController.searchBar.subView(of: "UIImageView") as? UIImageView,
           let textField = self.searchController.searchBar.subView(of: "UISearchBarTextField") as? UITextField {
            
            // Update the search text field icon and text color on macOS.
            if let attributedPlaceholder = textField.attributedPlaceholder {
                let tintColor = textField.isFocused ? UIColor.secondaryLabel : UIColor.label
                imageView.tintColor = tintColor
                let mutableAttributedPlaceholder = NSMutableAttributedString(
                    attributedString: attributedPlaceholder)
                mutableAttributedPlaceholder.addAttribute(
                    .foregroundColor, value: tintColor,
                    range: NSRange(location: 0, length: mutableAttributedPlaceholder.length))
                textField.attributedPlaceholder = mutableAttributedPlaceholder
            }
            
            // TODO: Currently in macOS 26 the search text field has not the correct height.
            if #available(macOS 26.0, *) {
                textField.anchorToSuperview()
            }
        }
        #endif
    }
    
    func setInitialLocation() {
        if let location = location {
            // present initial location if any
            self.location = location
            self.selectLocationButton.isHidden = false
            self.showCoordinates(location.coordinate, animated: false)
            return
        } else if showCurrentLocationInitially || selectCurrentLocationInitially {
            if self.selectCurrentLocationInitially {
                let listener = CurrentLocationListener(once: true) { [weak self] location in
                    if self?.location == nil { // user hasn't selected location still
                        self?.selectLocation(location: location)
                    }
                }
                self.currentLocationListeners.append(listener)
            }
            self.showCurrentLocation(false)
        }
    }
    
    func getCurrentLocation() {
        self.locationManager.startUpdatingLocation()
    }
    
    func showCurrentLocation(_ animated: Bool = true) {
        let listener = CurrentLocationListener(once: true) { [weak self] location in
            self?.showCoordinates(location.coordinate, animated: animated)
        }
        self.currentLocationListeners.append(listener)
        self.getCurrentLocation()
    }
    
    func updateAnnotation() {
        self.mapView.removeAnnotations(self.mapView.annotations)
        if let location = location {
            self.mapView.addAnnotation(location)
            self.mapView.selectAnnotation(location, animated: true)
        }
    }
    
    func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: self.resultRegionDistance,
            longitudinalMeters: self.resultRegionDistance)
        self.mapView.setRegion(region, animated: animated)
    }
    
    func selectLocation(location: CLLocation) {
        // Check if the user is connected to the internet.
        guard self.isConnectedToNetwork else {
            self.showNoInternetConnectionErrorDialog()
            return
        }
        
        // add point annotation to map
        let annotation = MKPointAnnotation()
        annotation.coordinate = location.coordinate
        self.mapView.addAnnotation(annotation)
        
        self.geocoder.cancelGeocode()
        self.geocoder.reverseGeocodeLocation(location) { response, error in
            if let error = error as NSError?, error.code != 10 { // ignore cancelGeocode errors
                // show error and remove annotation
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: self.okButtonTitle, style: .cancel, handler: { _ in }))
                self.present(alert, animated: true) {
                    self.mapView.removeAnnotation(annotation)
                }
            } else if let placemark = response?.first {
                // get POI name from placemark if any
                let name = placemark.areasOfInterest?.first
                
                // pass user selected location too
                self.location = Location(name: name, location: location, placemark: placemark)
                self.selectLocationButton.isHidden = false
            }
        }
    }
    
    // MARK: - Actions
    
    /// Occurs when the select location button has been clicked.
    ///
    /// - Parameter sender: The sender of the event.
    @IBAction func selectLocationButtonClicked(_ sender: Any) {
        self.completion?(location)
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
    
    /// Occurs when the clear location button has been clicked.
    ///
    /// - Parameter sender: The sender of the event.
    @IBAction func clearLocationButtonClicked(_ sender: Any) {
        self.completion?(nil)
        if let navigation = navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
}

// MARK: CLLocationManagerDelegate
extension LocationPickerViewController: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        self.currentLocationListeners.forEach { $0.action(location) }
        self.currentLocationListeners = self.currentLocationListeners.filter { !$0.once }
        manager.stopUpdatingLocation()
    }
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        
        var isAuthorized = false
        if #available(iOS 14.0, *) {
            switch manager.authorizationStatus {
            case .notDetermined:
                self.locationManager.requestAlwaysAuthorization()
                break
            case .authorizedWhenInUse:
                isAuthorized = true
                self.locationManager.startUpdatingLocation()
                break
            case .authorizedAlways:
                isAuthorized = true
                self.locationManager.startUpdatingLocation()
                break
            case .restricted:
                // restricted by e.g. parental controls. User can't enable Location Services
                break
            case .denied:
                // user denied your app access to Location Services, but can grant access from Settings.app
                // Hide the right bar button item.
                self.navigationItem.rightBarButtonItems = nil
                break
            default:
                break
            }
        } else {
            // Fallback on earlier versions
        }
        
        if isAuthorized, self.showCurrentLocationButton {
            var items: [UIBarButtonItem] = []
            let showLocationBarButtonItem = MKUserTrackingBarButtonItem(mapView: self.mapView)
            items.append(showLocationBarButtonItem)
            
            if self.location != nil {
                let clearLocationBarButtonItem = UIBarButtonItem(
                    title: NSLocalizedString("form_button_clear_title", comment: ""),
                    style: .plain,
                    target: self,
                    action: #selector(self.clearLocationButtonClicked))
                items.append(clearLocationBarButtonItem)
            }
            
            self.navigationItem.rightBarButtonItems = items
        }
    }
}

// MARK: Searching

extension LocationPickerViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        guard let term = searchController.searchBar.text else { return }
        
        self.searchTimer?.invalidate()
        
        let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
        
        if searchTerm.isEmpty {
            self.results.locations = self.historyManager.history()
            self.results.isShowingHistory = true
            self.results.tableView.reloadData()
        } else {
            // clear old results
            self.showItemsForSearchResult(nil)
            
            self.searchTimer = Timer.scheduledTimer(
                timeInterval: 0.2,
                target: self, selector: #selector(LocationPickerViewController.searchFromTimer(_:)),
                userInfo: [LocationPickerViewController.SearchTermKey: searchTerm],
                repeats: false)
        }
    }
    
    @objc func searchFromTimer(_ timer: Timer) {
        
        // Check if the user is connected to the internet.
        guard self.isConnectedToNetwork else {
            self.searchController.searchBar.text = nil
            self.showNoInternetConnectionErrorDialog()
            return
        }
        
        guard let userInfo = timer.userInfo as? [String: AnyObject],
              let term = userInfo[LocationPickerViewController.SearchTermKey] as? String
        else { return }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        
        if let location = self.locationManager.location, self.useCurrentLocationAsHint {
            request.region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        }
        
        self.localSearch?.cancel()
        self.localSearch = MKLocalSearch(request: request)
        self.localSearch!.start { response, _ in
            self.showItemsForSearchResult(response)
        }
    }
    
    func showItemsForSearchResult(_ searchResult: MKLocalSearch.Response?) {
        self.results.locations = searchResult?.mapItems.map {
            Location(name: $0.name, placemark: $0.placemark)
        } ?? []
        self.results.isShowingHistory = false
        self.results.tableView.reloadData()
    }
    
    func selectedLocation(_ location: Location) {
        // dismiss search results
        dismiss(animated: true) {
            // set location, this also adds annotation
            self.location = location
            self.selectLocationButton.isHidden = false
            self.showCoordinates(location.coordinate)
            
            self.historyManager.addToHistory(location)
        }
    }
    
    private func showNoInternetConnectionErrorDialog() {
        // Show alert and close search.
        let alert = UIAlertController(title: self.noInternetConnectionErrorTitle, message: self.noInternetConnectionErrorMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.okButtonTitle, style: .cancel, handler: { _ in }))
        self.present(alert, animated: true) {
            self.mapView.removeAnnotations(self.mapView.annotations)
            self.location = nil
            self.selectLocationButton.isHidden = true
        }
    }
}

// MARK: Selecting location with gesture

extension LocationPickerViewController {
    @objc func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: self.mapView)
            let coordinates = self.mapView.convert(point, toCoordinateFrom: self.mapView)
            let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
            
            // clean location, cleans out old annotation too
            self.location = nil
            self.selectLocation(location: location)
        }
    }
}

// MARK: MKMapViewDelegate

extension LocationPickerViewController: MKMapViewDelegate {
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation { return nil }
        
        let marker = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "annotation")
        marker.animatesWhenAdded = true
        marker.glyphTintColor = .white
        
        return marker
    }
    
    public func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        let pins = mapView.annotations.filter { $0 is MKPinAnnotationView }
        assert(pins.count <= 1, "Only 1 pin annotation should be on map at a time")
        
        if let userPin = views.first(where: { $0.annotation is MKUserLocation }) {
            userPin.canShowCallout = false
        }
    }
}

extension LocationPickerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer)
    -> Bool {
        return true
    }
}

// MARK: UISearchBarDelegate

extension LocationPickerViewController: UISearchBarDelegate {
    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        if let text = searchBar.text, text.isEmpty {
            searchBar.text = self.location?.address ?? " "
        }
    }
    
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        if searchText.isEmpty {
            self.location = nil
            self.selectLocationButton.isHidden = true
            searchBar.text = " "
        }
    }
}

fileprivate extension UIView {
    
    /// Returns the sub view which contains the specified class name.
    ///
    /// - Parameter className: The name of the parent view.
    /// - Returns: The sub view which contains the specified class name.
    func subView(of className: String) -> UIView? {
        
        // Initialize the result.
        var result: UIView?
        
        // First check the view itself.
        if String(describing: self).contains(className) {
            return self
        }
        
        // Then check all subviews of the view.
        for subview in self.subviews {
            result = subview.subView(of: className)
            
            // Return the result if a view has been found.
            if result != nil {
                return result
            }
        }
        
        // Return nil if no view has been found.
        return nil
    }
    
    /// Adds necessary constraints to anchor this view to the superview.
    ///
    /// - Parameters:
    ///    - edges: The edges to add the constraints to.
    ///    - useSafeArea: Indicates whether to use the safe area.
    ///    - padding: Indicates the padding to the superview.
    func anchorToSuperview(
        edges: UIRectEdge = .all,
        useSafeArea: Bool = false,
        padding: CGFloat = 0) {
        
        // Get the current superview.
        guard let superview = self.superview
        else {
            return
        }
        
        // Add new constraints.
        self.translatesAutoresizingMaskIntoConstraints = false
        var newAnchorConstraints: [NSLayoutConstraint] = []
        if edges.contains(.top) || edges.contains(.all) {
            newAnchorConstraints.append(
                topAnchor.constraint(
                    equalTo: useSafeArea ?
                        superview.safeAreaLayoutGuide.topAnchor :
                        superview.topAnchor,
                    constant: padding)
            )
        }
        
        if edges.contains(.bottom) || edges.contains(.all) {
            newAnchorConstraints.append(
                bottomAnchor.constraint(
                    equalTo: useSafeArea ?
                        superview.safeAreaLayoutGuide.bottomAnchor :
                        superview.bottomAnchor,
                    constant: -padding)
            )
        }
        
        if edges.contains(.left) || edges.contains(.all) {
            newAnchorConstraints.append(
                leadingAnchor.constraint(
                    equalTo: useSafeArea ?
                        superview.safeAreaLayoutGuide.leadingAnchor :
                        superview.leadingAnchor,
                    constant: padding)
            )
        }
        
        if edges.contains(.right) || edges.contains(.all) {
            newAnchorConstraints.append(
                trailingAnchor.constraint(
                    equalTo: useSafeArea ?
                        superview.safeAreaLayoutGuide.trailingAnchor :
                        superview.trailingAnchor,
                    constant: -padding)
            )
        }
        
        // Active the new constraints.
        NSLayoutConstraint.activate(newAnchorConstraints)
    }
}

public enum VariableBlurDirection {
    case blurredTopClearBottom
    case blurredBottomClearTop
}

/// credit https://github.com/jtrivedi/VariableBlurView
open class VariableBlurUIView: UIVisualEffectView {

    public init(maxBlurRadius: CGFloat = 20, direction: VariableBlurDirection = .blurredTopClearBottom, startOffset: CGFloat = 0) {
        super.init(effect: UIBlurEffect(style: .regular))

        let clsName = String("retliFAC".reversed())
        guard let Cls = NSClassFromString(clsName)! as? NSObject.Type else {
            print("[VariableBlur] Error: Can't find filter class")
            return
        }
        let selName = String(":epyThtiWretlif".reversed())
        guard let variableBlur = Cls.self.perform(NSSelectorFromString(selName), with: "variableBlur").takeUnretainedValue() as? NSObject else {
            print("[VariableBlur] Error: Can't create variableBlur filter")
            return
        }

        // The blur radius at each pixel depends on the alpha value of the corresponding pixel in the gradient mask.
        // An alpha of 1 results in the max blur radius, while an alpha of 0 is completely unblurred.
        let gradientImage = makeGradientImage(startOffset: startOffset, direction: direction)

        variableBlur.setValue(maxBlurRadius, forKey: "inputRadius")
        variableBlur.setValue(gradientImage, forKey: "inputMaskImage")
        variableBlur.setValue(true, forKey: "inputNormalizeEdges")

        // We use a `UIVisualEffectView` here purely to get access to its `CABackdropLayer`,
        // which is able to apply various, real-time CAFilters onto the views underneath.
        let backdropLayer = subviews.first?.layer

        // Replace the standard filters (i.e. `gaussianBlur`, `colorSaturate`, etc.) with only the variableBlur.
        backdropLayer?.filters = [variableBlur]
        
        // Get rid of the visual effect view's dimming/tint view, so we don't see a hard line.
        for subview in subviews.dropFirst() {
            subview.alpha = 0
        }
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override func didMoveToWindow() {
        // fixes visible pixelization at unblurred edge (https://github.com/nikstar/VariableBlur/issues/1)
        guard let window, let backdropLayer = subviews.first?.layer else { return }
        backdropLayer.setValue(window.traitCollection.displayScale, forKey: "scale")
    }
    
    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // `super.traitCollectionDidChange(previousTraitCollection)` crashes the app
    }
    
    private func makeGradientImage(width: CGFloat = 100, height: CGFloat = 100, startOffset: CGFloat, direction: VariableBlurDirection) -> CGImage { // much lower resolution might be acceptable
        let ciGradientFilter =  CIFilter.linearGradient()
//        let ciGradientFilter =  CIFilter.smoothLinearGradient()
        ciGradientFilter.color0 = CIColor.black
        ciGradientFilter.color1 = CIColor.clear
        ciGradientFilter.point0 = CGPoint(x: 0, y: height)
        ciGradientFilter.point1 = CGPoint(x: 0, y: startOffset * height) // small negative value looks better with vertical lines
        if case .blurredBottomClearTop = direction {
            ciGradientFilter.point0.y = 0
            ciGradientFilter.point1.y = height - ciGradientFilter.point1.y
        }
        return CIContext().createCGImage(ciGradientFilter.outputImage!, from: CGRect(x: 0, y: 0, width: width, height: height))!
    }
}
