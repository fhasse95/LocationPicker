//
//  Location.swift
//  LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Copyright (c) 2015 almassapargali. All rights reserved.
//

import Foundation
import Contacts
import CoreLocation
import AddressBookUI
import Contacts

// class because protocol
public class Location: NSObject {
	public let name: String?
	
	// difference from placemark location is that if location was reverse geocoded,
	// then location point to user selected location
	public let location: CLLocation
	public let placemark: CLPlacemark
	
    public var address: String {
        // try to build full address first
        if let addressDic = placemark.addressDictionary, let lines = addressDic["FormattedAddressLines"] as? [String] {
            return lines.joined(separator: ", ")
        }
        if #available(iOS 11.0, *), let postalAddress = placemark.postalAddress {
            return CNPostalAddressFormatter().string(from: postalAddress)
        }
        return "\(coordinate.latitude), \(coordinate.longitude)"
    }
	
	public init(name: String?, location: CLLocation? = nil, placemark: CLPlacemark) {
		self.name = name
		self.location = location ?? placemark.location!
		self.placemark = placemark
	}
}

import MapKit

extension Location: MKAnnotation {
    @objc public var coordinate: CLLocationCoordinate2D {
        return location?.coordinate ?? CLLocationCoordinate2D()
    }
    
    public var title: String? {
        return name ?? address
    }
}
