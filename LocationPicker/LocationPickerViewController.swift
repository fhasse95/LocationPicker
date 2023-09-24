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
    
    @available(iOS 13.0, *)
    public lazy var searchTextFieldColor: UIColor = .clear
    
    public var mapType: MKMapType = .hybrid {
        didSet {
            if isViewLoaded {
                mapView.mapType = mapType
            }
        }
    }
    
    public var location: Location? {
        didSet {
            if isViewLoaded {
                searchBar.text = location.flatMap({ $0.title }) ?? ""
                updateAnnotation()
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
    var selectLocationButton: UIButton?
    
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
            searchBar.searchTextField.backgroundColor = searchTextFieldColor
        }
        return searchBar
    }()
    
    deinit {
        searchTimer?.invalidate()
        localSearch?.cancel()
        geocoder.cancelGeocode()
    }
    
    open override func loadView() {
        mapView = MKMapView(frame: UIScreen.main.bounds)
        mapView.mapType = mapType
        view = mapView
        
        let selectLocationButton = UIButton(type: .system)
        selectLocationButton.isHidden = self.location == nil
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.filled()
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
        
        selectLocationButton.setTitle(selectButtonTitle, for: UIControl.State())
        selectLocationButton.addTarget(
            self,
            action: #selector(selectLocationButtonClicked(_:)),
            for: .touchUpInside)
        
        view.addSubview(selectLocationButton)
        
        // Update constraints.
        selectLocationButton.translatesAutoresizingMaskIntoConstraints = false
        selectLocationButton.heightAnchor.constraint(
            equalToConstant: 50)
        .isActive = true
        selectLocationButton.bottomAnchor.constraint(
            equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -50)
        .isActive = true
        selectLocationButton.leadingAnchor.constraint(
            equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 30)
        .isActive = true
        selectLocationButton.trailingAnchor.constraint(
            equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -30)
        .isActive = true
        
        self.selectLocationButton = selectLocationButton
        
        self.locationManagerDidChangeAuthorization(self.locationManager)
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        if #available(iOS 13.0, *), let navigationController = navigationController {
            let appearance = navigationController.navigationBar.standardAppearance
            appearance.backgroundColor = navigationController.navigationBar.barTintColor
            navigationItem.standardAppearance = appearance
            navigationItem.scrollEdgeAppearance = appearance
        }
        
        locationManager.delegate = self
        mapView.delegate = self
        searchBar.delegate = self
        
        // gesture recognizer for adding by tap
        let locationSelectGesture = UILongPressGestureRecognizer(
            target: self, action: #selector(addLocation(_:)))
        locationSelectGesture.delegate = self
        mapView.addGestureRecognizer(locationSelectGesture)
        
        // search
        if #available(iOS 11.0, *) {
            navigationItem.searchController = searchController
        } else {
            navigationItem.titleView = searchBar
            // http://stackoverflow.com/questions/32675001/uisearchcontroller-warning-attempting-to-load-the-view-of-a-view-controller/
            _ = searchController.view
        }
        definesPresentationContext = true
        
        // user location
        mapView.userTrackingMode = .none
        mapView.showsUserLocation = showCurrentLocationInitially || showCurrentLocationButton
        
        if useCurrentLocationAsHint {
            getCurrentLocation()
        }
    }
    
    open override var preferredStatusBarStyle : UIStatusBarStyle {
        return statusBarStyle
    }
    
    var presentedInitialLocation = false
    
    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        // setting initial location here since viewWillAppear is too early, and viewDidAppear is too late
        if !presentedInitialLocation {
            setInitialLocation()
            presentedInitialLocation = true
        }
    }
    
    func setInitialLocation() {
        if let location = location {
            // present initial location if any
            self.location = location
            self.selectLocationButton?.isHidden = false
            showCoordinates(location.coordinate, animated: false)
            return
        } else if showCurrentLocationInitially || selectCurrentLocationInitially {
            if selectCurrentLocationInitially {
                let listener = CurrentLocationListener(once: true) { [weak self] location in
                    if self?.location == nil { // user hasn't selected location still
                        self?.selectLocation(location: location)
                    }
                }
                currentLocationListeners.append(listener)
            }
            showCurrentLocation(false)
        }
    }
    
    func getCurrentLocation() {
        locationManager.startUpdatingLocation()
    }
    
    func showCurrentLocation(_ animated: Bool = true) {
        let listener = CurrentLocationListener(once: true) { [weak self] location in
            self?.showCoordinates(location.coordinate, animated: animated)
        }
        currentLocationListeners.append(listener)
        getCurrentLocation()
    }
    
    func updateAnnotation() {
        mapView.removeAnnotations(mapView.annotations)
        if let location = location {
            mapView.addAnnotation(location)
            mapView.selectAnnotation(location, animated: true)
        }
    }
    
    func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: resultRegionDistance, longitudinalMeters: resultRegionDistance)
        mapView.setRegion(region, animated: animated)
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
        mapView.addAnnotation(annotation)
        
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { response, error in
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
                self.selectLocationButton?.isHidden = false
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
            presentingViewController?.dismiss(animated: true, completion: nil)
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
            presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
}

// MARK: CLLocationManagerDelegate
extension LocationPickerViewController: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        currentLocationListeners.forEach { $0.action(location) }
        currentLocationListeners = currentLocationListeners.filter { !$0.once }
        manager.stopUpdatingLocation()
    }
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        
        var isAuthorized = false
        if #available(iOS 14.0, *) {
            switch manager.authorizationStatus {
            case .notDetermined:
                locationManager.requestAlwaysAuthorization()
                break
            case .authorizedWhenInUse:
                isAuthorized = true
                locationManager.startUpdatingLocation()
                break
            case .authorizedAlways:
                isAuthorized = true
                locationManager.startUpdatingLocation()
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
        
        if isAuthorized, showCurrentLocationButton {
            let clearLocationBarButtonItem = UIBarButtonItem(
                title: NSLocalizedString("form_button_clear_title", comment: ""),
                style: .plain,
                target: self,
                action: #selector(clearLocationButtonClicked(_:)))
            let showLocationBarButtonItem = MKUserTrackingBarButtonItem(mapView: mapView)
            self.navigationItem.rightBarButtonItems = [
                showLocationBarButtonItem,
                clearLocationBarButtonItem
            ]
        }
    }
}

// MARK: Searching

extension LocationPickerViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        guard let term = searchController.searchBar.text else { return }
        
        searchTimer?.invalidate()
        
        let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
        
        if searchTerm.isEmpty {
            results.locations = historyManager.history()
            results.isShowingHistory = true
            results.tableView.reloadData()
        } else {
            // clear old results
            showItemsForSearchResult(nil)
            
            searchTimer = Timer.scheduledTimer(timeInterval: 0.2,
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
        
        if let location = locationManager.location, useCurrentLocationAsHint {
            request.region = MKCoordinateRegion(center: location.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        }
        
        localSearch?.cancel()
        localSearch = MKLocalSearch(request: request)
        localSearch!.start { response, _ in
            self.showItemsForSearchResult(response)
        }
    }
    
    func showItemsForSearchResult(_ searchResult: MKLocalSearch.Response?) {
        results.locations = searchResult?.mapItems.map { Location(name: $0.name, placemark: $0.placemark) } ?? []
        results.isShowingHistory = false
        results.tableView.reloadData()
    }
    
    func selectedLocation(_ location: Location) {
        // dismiss search results
        dismiss(animated: true) {
            // set location, this also adds annotation
            self.location = location
            self.selectLocationButton?.isHidden = false
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
            self.selectLocationButton?.isHidden = true
        }
    }
}

// MARK: Selecting location with gesture

extension LocationPickerViewController {
    @objc func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: mapView)
            let coordinates = mapView.convert(point, toCoordinateFrom: mapView)
            let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
            
            // clean location, cleans out old annotation too
            self.location = nil
            selectLocation(location: location)
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
        // dirty hack to show history when there is no text in search bar
        // to be replaced later (hopefully)
        if let text = searchBar.text, text.isEmpty {
            searchBar.text = " "
        }
    }
    
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // remove location if user presses clear or removes text
        if searchText.isEmpty {
            location = nil
            self.selectLocationButton?.isHidden = true
            searchBar.text = " "
        }
    }
}
