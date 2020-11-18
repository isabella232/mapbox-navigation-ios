import UIKit
import MapboxCoreNavigation
import MapboxNavigation
import MapboxDirections
import Turf

private typealias RouteRequestSuccess = ((RouteResponse) -> Void)
private typealias RouteRequestFailure = ((Error) -> Void)

private enum RouteETAAnnotationTailPosition: Int {
    case left
    case right
}

class ViewController: UIViewController {
    // MARK: - IBOutlets
    @IBOutlet weak var longPressHintView: UIView!
    @IBOutlet weak var simulationButton: UIButton!
    @IBOutlet weak var startButton: UIButton!
    @IBOutlet weak var bottomBar: UIView!
    @IBOutlet weak var clearMap: UIButton!
    @IBOutlet weak var bottomBarBackground: UIView!
    
    var trackPolyline: MGLPolyline?
    var rawTrackPolyline: MGLPolyline?
    
    // MARK: Properties
    var mapView: NavigationMapView? {
        didSet {
            if let mapView = oldValue {
                uninstall(mapView)
            }
            if let mapView = mapView {
                configureMapView(mapView)
                view.insertSubview(mapView, belowSubview: longPressHintView)
            }
        }
    }
    var waypoints: [Waypoint] = [] {
        didSet {
            waypoints.forEach {
                $0.coordinateAccuracy = -1
            }
        }
    }

    var response: RouteResponse? {
        didSet {
            guard let routes = response?.routes, let currentRoute = routes.first else {
                clearMapView()
                return
            }
            
            startButton.isEnabled = true
            mapView?.show(routes)
            mapView?.showWaypoints(on: currentRoute)
            if let style = mapView?.style {
                // show route Duration and Toll annotations
                updateRouteAnnotations(routes, style: style)
            }
        }
    }

    fileprivate let dateComponentsFormatter = DateComponentsFormatter()

    private func updateAnnotationSymbolImages(_ style: MGLStyle) {
        let capInsetHeight = CGFloat(22)
        let capInsetWidth = CGFloat(11)
        let capInsets = UIEdgeInsets(top: capInsetHeight, left: capInsetWidth, bottom: capInsetHeight, right: capInsetWidth)
        if let image = UIImage(named: "RouteInfoAnnotationLeftHanded") {
            let regularRouteImage = image.tint(UIColor.white).resizableImage(withCapInsets: capInsets, resizingMode: .stretch)
            style.setImage(regularRouteImage, forName: "RouteInfoAnnotationLeftHanded")

            let selectedRouteImage = image.tint(#colorLiteral(red: 0.337254902, green: 0.6588235294, blue: 0.9843137255, alpha: 1)).resizableImage(withCapInsets: capInsets, resizingMode: .stretch)
            style.setImage(selectedRouteImage, forName: "RouteInfoAnnotationLeftHanded-Selected")
        }

        if let image = UIImage(named: "RouteInfoAnnotationRightHanded") {
            let regularRouteImage = image.tint(UIColor.white).resizableImage(withCapInsets: capInsets, resizingMode: .stretch)
            style.setImage(regularRouteImage, forName: "RouteInfoAnnotationRightHanded")

            let selectedRouteImage = image.tint(#colorLiteral(red: 0.337254902, green: 0.6588235294, blue: 0.9843137255, alpha: 1)).resizableImage(withCapInsets: capInsets, resizingMode: .stretch)
            style.setImage(selectedRouteImage, forName: "RouteInfoAnnotationRightHanded-Selected")
        }
    }

    private func updateRouteAnnotations(_ routes: [Route]?, style: MGLStyle) {
        // remove any existing route annotation
        removeRouteAnnotationsLayerFromStyle(style)

        guard waypoints.count > 0, let routes = routes, let mapView = mapView else { return }

        let visibleBoundingBox = BoundingBox(coordinateBounds: mapView.visibleCoordinateBounds)

        let tollRoutes = routes.filter { route -> Bool in
            return (route.tollIntersections?.count ?? 0) > 0
        }
        let routesContainTolls = tollRoutes.count > 0

        // Run through our heurstic algorithm looking for a good coordinate along each route line to place it's route annotation
        guard let selectedRoute = routes.first else { return }

        guard let visibleSelectedRoute = selectedRoute.shapes(within: visibleBoundingBox), let selectedRouteShape = visibleSelectedRoute.first else { return }

        // simplify the polyline of the selected route shape to reduce number of points considered
        let selectedRouteLine = selectedRouteShape.coordinates.count < 100 ? selectedRouteShape : selectedRouteShape.simplified

        // filter to only vertices that are onscreen
        let visibleRouteCoordinates = selectedRouteLine.coordinates.filter {
            let unprojectedPoint = mapView.convert($0, toPointTo: nil)
            return mapView.bounds.contains(unprojectedPoint)
        }

        // pick a random vertex as our annotation coordinate
        guard let selectedRouteCoordinate = visibleRouteCoordinates.randomElement() else { return }

        let selectedRouteTailPosition = mapView.convert(selectedRouteCoordinate, toPointTo: nil).x <= mapView.bounds.width / 2 ? RouteETAAnnotationTailPosition.left : RouteETAAnnotationTailPosition.right

        var features = [MGLPointFeature]()

        // we will look for a set of RouteSteps unique to each alternate route, then find a coordinate along that portion of the route line
        // to use as the position of the annotation callout for that route
        var excludedSteps = selectedRoute.legs.compactMap { return $0.steps }.reduce([], +)
        for (index, route) in routes.dropFirst().enumerated() {
            let allSteps = route.legs.compactMap { return $0.steps }.reduce([], +)
            let alternateSteps = allSteps.filter { step -> Bool in
                for existingStep in excludedSteps {
                    if step == existingStep {
                        return false
                    }
                }
                return true
            }

            excludedSteps.append(contentsOf: alternateSteps)
            let visibleAlternateSteps = alternateSteps.filter { $0.intersects(visibleBoundingBox) }

            var coordinate = kCLLocationCoordinate2DInvalid

            // Obtain a polyline of the set of steps. We'll look for a good spot along this line to place the annotation
            if let continuousLine = visibleAlternateSteps.continuousShape(), continuousLine.coordinates.count > 0 {
                coordinate = continuousLine.coordinates[0]

                // We don't need a full resolution polyline in order to find our spot so simplify any complex shapes with many vertices
                let simplifiedLine = continuousLine.coordinates.count < 100 ? continuousLine : continuousLine.simplified

                // find the on-screen vertex that is the furthest from the location of the selected route's annotation
                // this will usually yield a coordinate that is visually far enough to not overlap
                let distanceSortedVertices = simplifiedLine.coordinates
                    .filter {
                        let unprojectedPoint = mapView.convert($0, toPointTo: nil)
                        return mapView.bounds.contains(unprojectedPoint)
                    }
                    .sorted { $0.distance(to: selectedRouteCoordinate) < $1.distance(to: selectedRouteCoordinate) }

                let furthestDistance = distanceSortedVertices.last?.distance(to: selectedRouteCoordinate) ?? 0
                var furthestVertex = kCLLocationCoordinate2DInvalid

                // look for a vertex that is "far enough" from the selected annotation coordinate. We do this so we don't always put the annotations at the end of the route line.
                for vertex in distanceSortedVertices {
                    if vertex.distance(to: selectedRouteCoordinate) >= furthestDistance * 0.75 {
                        furthestVertex = vertex
                        break
                    }
                }

                if furthestVertex != kCLLocationCoordinate2DInvalid {
                    coordinate = continuousLine.closestCoordinate(to: furthestVertex)?.coordinate ?? furthestVertex
                }
            }

            // form the appropriate text string for the annotation
            let labelText = annotationLabelForRoute(route, tolls: routesContainTolls)

            // convert our coordinate to screen space so we make some choices on which side of the coordinate the label ends up on
            let unprojectedCoordinate = mapView.convert(coordinate, toPointTo: nil)

            // Create the feature for this route annotation. Set the styling attributes that will be used to render the annotation in the style layer.
            let point = MGLPointFeature()
            point.coordinate = coordinate
            var tailPosition = selectedRouteTailPosition == .left ? RouteETAAnnotationTailPosition.right : RouteETAAnnotationTailPosition.left

            // pick the orientation of the bubble "stem" based on how close to the edge of the screen it is
            if tailPosition == .left && unprojectedCoordinate.x > mapView.bounds.width * 0.75 {
                tailPosition = .right
            } else if tailPosition == .right && unprojectedCoordinate.x < mapView.bounds.width * 0.25 {
                tailPosition = .left
            }

            let imageName = tailPosition == .left ? "RouteInfoAnnotationLeftHanded" : "RouteInfoAnnotationRightHanded"
            point.attributes = ["selected": false, "tailPosition": tailPosition.rawValue, "text": labelText, "imageName": imageName, "sortOrder": -index]

            features.append(point)
        }

        // add the annotation for the selected annotation last so it ends up ordered on top of the others
        let labelText = annotationLabelForRoute(selectedRoute, tolls: routesContainTolls)

        let point = MGLPointFeature()
        point.coordinate = selectedRouteCoordinate
        point.attributes = ["selected": true, "tailPosition": selectedRouteTailPosition.rawValue, "text": labelText, "imageName": selectedRouteTailPosition == .left ? "RouteInfoAnnotationLeftHanded-Selected" : "RouteInfoAnnotationRightHanded-Selected"]
        features.append(point)

        // add the features to the style
        addRouteAnnotationSymbolLayer(features: features, style: style)
    }

    private let annotationLayerIdentifier = "RouteETAAnnotations"

    private func addRouteAnnotationSymbolLayer(features: [MGLPointFeature], style: MGLStyle) {
        let dataSource: MGLShapeSource
        if let source = style.source(withIdentifier: annotationLayerIdentifier + "-source") as? MGLShapeSource {
            dataSource = source
        } else {
            dataSource = MGLShapeSource(identifier: annotationLayerIdentifier + "-source", features: features, options: nil)
            style.addSource(dataSource)
        }

        let shapeLayer: MGLSymbolStyleLayer

        if let layer = style.layer(withIdentifier: annotationLayerIdentifier + "-shape") as? MGLSymbolStyleLayer {
            shapeLayer = layer
        } else {
            shapeLayer = MGLSymbolStyleLayer(identifier: annotationLayerIdentifier + "-shape", source: dataSource)
        }

        shapeLayer.text = NSExpression(forKeyPath: "text")
        let fontSizeByZoomLevel = [
            13: NSExpression(forConstantValue: 16),
            15.5: NSExpression(forConstantValue: 20)
        ]
        shapeLayer.textFontSize = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)", fontSizeByZoomLevel)

        shapeLayer.textColor = NSExpression(forConditional: NSPredicate(format: "selected == true"),
                                            trueExpression: NSExpression(forConstantValue: UIColor.white),
                     falseExpression: NSExpression(forConstantValue: UIColor.black))

        shapeLayer.textFontNames = NSExpression(forConstantValue: ["DIN Pro Medium"])
        shapeLayer.textAllowsOverlap = NSExpression(forConstantValue: true)
        shapeLayer.textJustification = NSExpression(forConstantValue: "left")
        shapeLayer.symbolZOrder = NSExpression(forConstantValue: NSValue(mglSymbolZOrder: MGLSymbolZOrder.auto))
        shapeLayer.symbolSortKey = NSExpression(forConditional: NSPredicate(format: "selected == true"),
                                                trueExpression: NSExpression(forConstantValue: 1),
                                                   falseExpression: NSExpression(format: "sortOrder"))
        shapeLayer.iconAnchor = NSExpression(forConditional: NSPredicate(format: "tailPosition == 0"),
                                             trueExpression: NSExpression(forConstantValue: "bottom-left"),
                                                falseExpression: NSExpression(forConstantValue: "bottom-right"))
        shapeLayer.textAnchor = shapeLayer.iconAnchor
        shapeLayer.iconTextFit = NSExpression(forConstantValue: "both")

        shapeLayer.iconImageName = NSExpression(forKeyPath: "imageName")
        shapeLayer.iconOffset = NSExpression(forConditional: NSPredicate(format: "tailPosition == 0"),
                                             trueExpression: NSExpression(forConstantValue: CGVector(dx: 0.5, dy: -1.0)),
                      falseExpression: NSExpression(forConstantValue: CGVector(dx: -0.5, dy: -1.0)))
        shapeLayer.textOffset = shapeLayer.iconOffset
        shapeLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)

        style.addLayer(shapeLayer)
    }

    private func removeRouteAnnotationsLayerFromStyle(_ style: MGLStyle) {
        if let annotationsLayer = style.layer(withIdentifier: annotationLayerIdentifier + "-shape") {
            style.removeLayer(annotationsLayer)
        }

        if let annotationsSource = style.source(withIdentifier: annotationLayerIdentifier + "-source") {
            style.removeSource(annotationsSource)
        }
    }

    // This function generates the text for the label to be shown on screen. It will include estimated duration and info on Tolls, if applicable
    private func annotationLabelForRoute(_ route: Route, tolls: Bool) -> String {
        var eta = dateComponentsFormatter.string(from: route.expectedTravelTime) ?? ""

        let hasTolls = (route.tollIntersections?.count ?? 0) > 0
        if hasTolls {
            eta += "\n" + NSLocalizedString("ROUTE_HAS_TOLLS", value: "Tolls", comment: "This route does have tolls")
            if let symbol = Locale.current.currencySymbol {
                eta += " " + symbol
            }
        } else if tolls {
            // If one of the routes has tolls, but this one does not then it needs to explicitly say that it has no tolls
            // If no routes have tolls at all then we can omit this portion of the string.
            eta += "\n" + NSLocalizedString("ROUTE_HAS_NO_TOLLS", value: "No Tolls", comment: "This route does not have tolls")
        }

        return eta
    }
    
    weak var activeNavigationViewController: NavigationViewController?

    // MARK: Directions Request Handlers

    fileprivate lazy var defaultSuccess: RouteRequestSuccess = { [weak self] (response) in
        guard let routes = response.routes, !routes.isEmpty, case let .route(options) = response.options else { return }
        self?.mapView?.removeWaypoints()
        self?.response = response
        
        // Waypoints which were placed by the user are rewritten by slightly changed waypoints
        // which are returned in response with routes.
        if let waypoints = response.waypoints {
            self?.waypoints = waypoints
        }
        
        self?.clearMap.isHidden = false
        self?.longPressHintView.isHidden = true
    }

    fileprivate lazy var defaultFailure: RouteRequestFailure = { [weak self] (error) in
        self?.response = nil //clear routes from the map
        print(error.localizedDescription)
        self?.presentAlert(message: error.localizedDescription)
    }
    
    private var foundAllBuildings = false

    // MARK: - Init
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    private func commonInit() {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.currentAppRootViewController = self
        }

        dateComponentsFormatter.maximumUnitCount = 3
        dateComponentsFormatter.allowedUnits = [.hour, .minute]
        dateComponentsFormatter.unitsStyle = .short
    }
    
    deinit {
        if let mapView = mapView {
            uninstall(mapView)
        }
    }
    
    // MARK: - Lifecycle Methods

    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(named: "settings"), style: .plain, target: self, action: #selector(openSettings))

        navigationItem.rightBarButtonItem?.isEnabled = SettingsViewController.numberOfSections > 0
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if mapView == nil {
            mapView = NavigationMapView(frame: view.bounds)
        }
        
        // Reset the navigation styling to the defaults if we are returning from a presentation.
        if (presentedViewController != nil) {
            DayStyle().apply()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                CLLocationManager().requestWhenInUseAuthorization()
            }
        }
    }
    
    @IBAction func openSettings() {
        let controller = UINavigationController(rootViewController: SettingsViewController())
        present(controller, animated: true, completion: nil)
    }

    // MARK: Gesture Recognizer Handlers

    @objc func didLongPress(tap: UILongPressGestureRecognizer) {
        guard let mapView = mapView, tap.state == .began else { return }

        if let annotation = mapView.annotations?.last, waypoints.count > 2 {
            mapView.removeAnnotation(annotation)
        }

        if waypoints.count > 1 {
            waypoints = Array(waypoints.dropFirst())
        }
        
        let destinationCoord = mapView.convert(tap.location(in: mapView), toCoordinateFrom: mapView)
        // Note: The destination name can be modified. The value is used in the top banner when arriving at a destination.
        let waypoint = Waypoint(coordinate: destinationCoord, name: "Dropped Pin #\(waypoints.endIndex + 1)")
        // Example of building highlighting. `targetCoordinate`, in this example, is used implicitly by NavigationViewController to determine which buildings to highlight.
        waypoint.targetCoordinate = destinationCoord
        waypoints.append(waypoint)
    
        // Example of highlighting buildings in 2d and directly using the API on NavigationMapView.
        let buildingHighlightCoordinates = waypoints.compactMap { $0.targetCoordinate }
        foundAllBuildings = mapView.highlightBuildings(at: buildingHighlightCoordinates, in3D: false)

        requestRoute()
    }

    // MARK: - IBActions

    @IBAction func simulateButtonPressed(_ sender: Any) {
        simulationButton.isSelected = !simulationButton.isSelected
    }

    @IBAction func clearMapPressed(_ sender: Any) {
        clearMapView()
    }

    @IBAction func startButtonPressed(_ sender: Any) {
        presentActionsAlertController()
    }
    
    private func clearMapView() {
        startButton.isEnabled = false
        clearMap.isHidden = true
        longPressHintView.isHidden = false

        if let style = mapView?.style {
            removeRouteAnnotationsLayerFromStyle(style)
            style.removeDebugLineLayers()
            style.removeDebugCircleLayers()
        }
        
        mapView?.unhighlightBuildings()
        mapView?.removeRoutes()
        mapView?.removeWaypoints()
        waypoints.removeAll()
    }
    
    private func presentActionsAlertController() {
        let alertController = UIAlertController(title: "Start Navigation", message: "Select the navigation type", preferredStyle: .actionSheet)
        
        typealias ActionHandler = (UIAlertAction) -> Void
        
        let basic: ActionHandler = { _ in self.startBasicNavigation() }
        let day: ActionHandler = { _ in self.startNavigation(styles: [DayStyle()]) }
        let night: ActionHandler = { _ in self.startNavigation(styles: [NightStyle()]) }
        let custom: ActionHandler = { _ in self.startCustomNavigation() }
        let styled: ActionHandler = { _ in self.startStyledNavigation() }
        let guidanceCards: ActionHandler = { _ in self.startGuidanceCardsNavigation() }
        
        let actionPayloads: [(String, UIAlertAction.Style, ActionHandler?)] = [
            ("Default UI", .default, basic),
            ("DayStyle UI", .default, day),
            ("NightStyle UI", .default, night),
            ("Custom UI", .default, custom),
            ("Guidance Card UI", .default, guidanceCards),
            ("Styled UI", .default, styled),
            ("Cancel", .cancel, nil)
        ]
        
        actionPayloads
            .map { payload in UIAlertAction(title: payload.0, style: payload.1, handler: payload.2) }
            .forEach(alertController.addAction(_:))
        
        if let popoverController = alertController.popoverPresentationController {
            popoverController.sourceView = self.startButton
            popoverController.sourceRect = self.startButton.bounds
        }
        
        present(alertController, animated: true, completion: nil)
    }

    // MARK: - Public Methods
    // MARK: Route Requests
    func requestRoute() {
        guard waypoints.count > 0 else { return }
        guard let mapView = mapView else { return }
        guard let userLocation = mapView.userLocation?.location else {
            print("User location is not valid. Make sure to enable Location Services.")
            return
        }
        
        let userWaypoint = Waypoint(location: userLocation, heading: mapView.userLocation?.heading, name: "User location")
        waypoints.insert(userWaypoint, at: 0)

        let options = NavigationRouteOptions(waypoints: waypoints)
        
        // Get periodic updates regarding changes in estimated arrival time and traffic congestion segments along the route line.
        RouteControllerProactiveReroutingInterval = 30

        requestRoute(with: options, success: defaultSuccess, failure: defaultFailure)
    }

    fileprivate func requestRoute(with options: RouteOptions, success: @escaping RouteRequestSuccess, failure: RouteRequestFailure?) {
        Directions.shared.calculate(options) { (session, result) in
            switch result {
            case let .success(response):
                success(response)
            case let .failure(error):
                failure?(error)
            }
        }
    }

    // MARK: Basic Navigation

    func startBasicNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let service = navigationService(route: route, routeIndex: 0, options: routeOptions)
        let navigationViewController = self.navigationViewController(navigationService: service)
        
        // Render part of the route that has been traversed with full transparency, to give the illusion of a disappearing route.
        navigationViewController.routeLineTracksTraversal = true
        
        // Example of building highlighting in 3D.
        navigationViewController.waypointStyle = .extrudedBuilding
        navigationViewController.detailedFeedbackEnabled = true
        
        // Show second level of detail for feedback items.
        navigationViewController.detailedFeedbackEnabled = true
        
        presentAndRemoveMapview(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    func startNavigation(styles: [Style]) {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let options = NavigationOptions(styles: styles, navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions))
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self
        
        // Example of building highlighting in 2D.
        navigationViewController.waypointStyle = .building
        
        presentAndRemoveMapview(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    func navigationViewController(navigationService: NavigationService) -> NavigationViewController {
        let options = NavigationOptions(navigationService: navigationService)
        
        let navigationViewController = NavigationViewController(for: navigationService.route, routeIndex: navigationService.indexedRoute.1, routeOptions: navigationService.routeProgress.routeOptions, navigationOptions: options)
        navigationViewController.delegate = self
        navigationViewController.mapView?.delegate = self
        return navigationViewController
    }
    
    public func beginNavigationWithCarplay(navigationService: NavigationService) {
        let navigationViewController = activeNavigationViewController ?? self.navigationViewController(navigationService: navigationService)
        navigationViewController.didConnectToCarPlay()

        guard activeNavigationViewController == nil else { return }

        presentAndRemoveMapview(navigationViewController, completion: nil)
    }
    
    // MARK: Custom Navigation UI
    func startCustomNavigation() {
        guard let route = response?.routes?.first, let responseOptions = response?.options, case let .route(routeOptions) = responseOptions else { return }

        guard let customViewController = storyboard?.instantiateViewController(withIdentifier: "custom") as? CustomViewController else { return }

        customViewController.userIndexedRoute = (route, 0)
        customViewController.userRouteOptions = routeOptions

        let destination = MGLPointAnnotation()
        destination.coordinate = route.shape!.coordinates.last!
        customViewController.destination = destination
        customViewController.simulateLocation = simulationButton.isSelected

        present(customViewController, animated: true, completion: nil)
    }

    // MARK: Styling the default UI

    func startStyledNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }

        let styles = [CustomDayStyle(), CustomNightStyle()]
        let options = NavigationOptions(styles: styles, navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions))
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self

        presentAndRemoveMapview(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    // MARK: Guidance Cards
    func startGuidanceCardsNavigation() {
        guard let response = response, let route = response.routes?.first, case let .route(routeOptions) = response.options else { return }
        
        let instructionsCardCollection = InstructionsCardViewController()
        instructionsCardCollection.cardCollectionDelegate = self
        
        let options = NavigationOptions(navigationService: navigationService(route: route, routeIndex: 0, options: routeOptions), topBanner: instructionsCardCollection)
        let navigationViewController = NavigationViewController(for: route, routeIndex: 0, routeOptions: routeOptions, navigationOptions: options)
        navigationViewController.delegate = self
        
        presentAndRemoveMapview(navigationViewController, completion: beginCarPlayNavigation)
    }
    
    func navigationService(route: Route, routeIndex: Int, options: RouteOptions) -> NavigationService {
        let simulate = simulationButton.isSelected
        let mode: SimulationMode = simulate ? .always : .onPoorGPS
        return MapboxNavigationService(route: route, routeIndex: routeIndex, routeOptions: options, simulating: mode)
    }

    func presentAndRemoveMapview(_ navigationViewController: NavigationViewController, completion: CompletionHandler?) {
        navigationViewController.modalPresentationStyle = .fullScreen
        activeNavigationViewController = navigationViewController
        
        present(navigationViewController, animated: true) { [weak self] in
            completion?()
            
            self?.mapView = nil
        }
    }
    
    func beginCarPlayNavigation() {
        let delegate = UIApplication.shared.delegate as? AppDelegate
        
        if #available(iOS 12.0, *),
            let service = activeNavigationViewController?.navigationService,
            let location = service.router.location {
            delegate?.carPlayManager.beginNavigationWithCarPlay(using: location.coordinate,
                                                                navigationService: service)
        }
    }
    
    func endCarPlayNavigation(canceled: Bool) {
        if #available(iOS 12.0, *), let delegate = UIApplication.shared.delegate as? AppDelegate {
            delegate.carPlayManager.currentNavigator?.exitNavigation(byCanceling: canceled)
        }
    }
    
    func dismissActiveNavigationViewController() {
        activeNavigationViewController?.dismiss(animated: true) {
            self.activeNavigationViewController = nil
        }
    }

    func configureMapView(_ mapView: NavigationMapView) {
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.navigationMapViewDelegate = self
        mapView.logoView.isHidden = true

        let singleTap = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(tap:)))
        mapView.gestureRecognizers?.filter({ $0 is UILongPressGestureRecognizer }).forEach(singleTap.require(toFail:))
        mapView.addGestureRecognizer(singleTap)
        
        trackLocations(mapView: mapView)
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.showsUserHeadingIndicator = true
    }
    
    func uninstall(_ mapView: NavigationMapView) {
        NotificationCenter.default.removeObserver(self, name: .passiveLocationDataSourceDidUpdate, object: nil)
        mapView.removeFromSuperview()
    }
}

extension ViewController: MGLMapViewDelegate {
    func mapView(_ mapView: MGLMapView, didFinishLoading style: MGLStyle) {
        guard mapView == self.mapView else {
            return
        }

        self.mapView?.localizeLabels()

        self.updateAnnotationSymbolImages(style)

        if let routes = response?.routes, let currentRoute = routes.first, let coords = currentRoute.shape?.coordinates {
            mapView.setVisibleCoordinateBounds(MGLPolygon(coordinates: coords, count: UInt(coords.count)).overlayBounds, animated: false)
            self.mapView?.show(routes)
            self.mapView?.showWaypoints(on: currentRoute)
        }
    }
    
    func mapView(_ mapView: MGLMapView, strokeColorForShapeAnnotation annotation: MGLShape) -> UIColor {
        if annotation == trackPolyline {
            return .darkGray
        }
        if annotation == rawTrackPolyline {
            return .lightGray
        }
        return .black
    }
    
    func mapView(_ mapView: MGLMapView, lineWidthForPolylineAnnotation annotation: MGLPolyline) -> CGFloat {
        return annotation == trackPolyline || annotation == rawTrackPolyline ? 4 : 1
    }
    
    func mapViewRegionIsChanging(_ mapView: MGLMapView) {
        if activeNavigationViewController == nil, foundAllBuildings == false, let navMapView = mapView as? NavigationMapView {
            let buildingHighlightCoordinates = waypoints.compactMap { $0.targetCoordinate }
            if buildingHighlightCoordinates.count > 0 {
                foundAllBuildings = navMapView.highlightBuildings(at: buildingHighlightCoordinates, in3D: false)
            }
        }
    }

    func mapView(_ mapView: MGLMapView, regionDidChangeWith reason: MGLCameraChangeReason, animated: Bool) {
        if let style = mapView.style, let routes = response?.routes {
            updateRouteAnnotations(routes, style: style)
        }
    }
}

// MARK: - NavigationMapViewDelegate
extension ViewController: NavigationMapViewDelegate {
    func navigationMapView(_ mapView: NavigationMapView, didSelect waypoint: Waypoint) {
        guard let responseOptions = response?.options, case let .route(routeOptions) = responseOptions else { return }
        let modifiedOptions = routeOptions.without(waypoint: waypoint)

        presentWaypointRemovalAlert { _ in
            self.requestRoute(with:modifiedOptions, success: self.defaultSuccess, failure: self.defaultFailure)
        }
    }

    func navigationMapView(_ mapView: NavigationMapView, didSelect route: Route) {
        guard let routes = response?.routes else { return }
        guard let index = routes.firstIndex(where: { $0 === route }) else { return }
        self.response!.routes!.remove(at: index)
        self.response!.routes!.insert(route, at: 0)
    }

    private func presentWaypointRemovalAlert(completionHandler approve: @escaping ((UIAlertAction) -> Void)) {
        let title = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_TITLE", value: "Remove Waypoint?", comment: "Title of alert confirming waypoint removal")
        let message = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_MSG", value: "Do you want to remove this waypoint?", comment: "Message of alert confirming waypoint removal")
        let removeTitle = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_REMOVE", value: "Remove Waypoint", comment: "Title of alert action for removing a waypoint")
        let cancelTitle = NSLocalizedString("REMOVE_WAYPOINT_CONFIRM_CANCEL", value: "Cancel", comment: "Title of action for dismissing waypoint removal confirmation sheet")
        
        let waypointRemovalAlertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: removeTitle, style: .destructive, handler: approve)
        let cancelAction = UIAlertAction(title: cancelTitle, style: .cancel, handler: nil)
        [removeAction, cancelAction].forEach(waypointRemovalAlertController.addAction(_:))
        
        self.present(waypointRemovalAlertController, animated: true, completion: nil)
    }
}

// MARK: RouteVoiceControllerDelegate methods
// To use these delegate methods, set the `routeVoiceControllerDelegate` on your `VoiceController`.
extension ViewController: RouteVoiceControllerDelegate {
    // Called when there is an error with instructions vocalization
    func routeVoiceController(_ routeVoiceController: RouteVoiceController, encountered error: SpeechError) {
        print(error)

    }
    
    // By default, the navigation service will attempt to filter out unqualified locations.
    // If however you would like to filter these locations in,
    // you can conditionally return a Bool here according to your own heuristics.
    // See CLLocation.swift `isQualified` for what makes a location update unqualified.
    func navigationViewController(_ navigationViewController: NavigationViewController, shouldDiscard location: CLLocation) -> Bool {
        return true
    }
    
    func navigationViewController(_ navigationViewController: NavigationViewController, shouldRerouteFrom location: CLLocation) -> Bool {
        return true
    }
}

// MARK: WaypointConfirmationViewControllerDelegate
extension ViewController: WaypointConfirmationViewControllerDelegate {
    func confirmationControllerDidConfirm(_ confirmationController: WaypointConfirmationViewController) {
        confirmationController.dismiss(animated: true, completion: {
            guard let navigationViewController = self.presentedViewController as? NavigationViewController,
                let navService = navigationViewController.navigationService else { return }

            navService.router?.advanceLegIndex()
            navService.start()

            navigationViewController.mapView?.unhighlightBuildings()
        })
    }
}

// MARK: NavigationViewControllerDelegate
extension ViewController: NavigationViewControllerDelegate {
    // By default, when the user arrives at a waypoint, the next leg starts immediately.
    // If you implement this method, return true to preserve this behavior.
    // Return false to remain on the current leg, for example to allow the user to provide input.
    // If you return false, you must manually advance to the next leg. See the example above in `confirmationControllerDidConfirm(_:)`.
    func navigationViewController(_ navigationViewController: NavigationViewController, didArriveAt waypoint: Waypoint) -> Bool {
        // When the user arrives, present a view controller that prompts the user to continue to their next destination
        // This type of screen could show information about a destination, pickup/dropoff confirmation, instructions upon arrival, etc.
        
        //If we're not in a "Multiple Stops" demo, show the normal EORVC
        if navigationViewController.navigationService.router.routeProgress.isFinalLeg {
            endCarPlayNavigation(canceled: false)
            return true
        }
        
        guard let confirmationController = self.storyboard?.instantiateViewController(withIdentifier: "waypointConfirmation") as? WaypointConfirmationViewController else {
            return true
        }

        confirmationController.delegate = self

        navigationViewController.present(confirmationController, animated: true, completion: nil)
        return false
    }
    
    // Called when the user hits the exit button.
    // If implemented, you are responsible for also dismissing the UI.
    func navigationViewControllerDidDismiss(_ navigationViewController: NavigationViewController, byCanceling canceled: Bool) {
        endCarPlayNavigation(canceled: canceled)
        dismissActiveNavigationViewController()
        if mapView == nil {
            mapView = NavigationMapView(frame: view.bounds)
        }
    }
}

// MARK: VisualInstructionDelegate
extension ViewController: VisualInstructionDelegate {
    func label(_ label: InstructionLabel, willPresent instruction: VisualInstruction, as presented: NSAttributedString) -> NSAttributedString? {
        // Uncomment to mutate the instruction shown in the top instruction banner
        // let range = NSRange(location: 0, length: presented.length)
        // let mutable = NSMutableAttributedString(attributedString: presented)
        // mutable.mutableString.applyTransform(.latinToKatakana, reverse: false, range: range, updatedRange: nil)
        // return mutable
        
        return presented
    }
}

// MARK: Free driving
extension ViewController {
    func trackLocations(mapView: NavigationMapView) {
        let dataSource = PassiveLocationDataSource()
        let locationManager = PassiveLocationManager(dataSource: dataSource)
        mapView.locationManager = locationManager
        
        NotificationCenter.default.addObserver(self, selector: #selector(didUpdatePassiveLocation), name: .passiveLocationDataSourceDidUpdate, object: dataSource)
        
        trackPolyline = nil
        rawTrackPolyline = nil
    }
    
    @objc func didUpdatePassiveLocation(_ notification: Notification) {
        if let roadName = notification.userInfo?[PassiveLocationDataSource.NotificationUserInfoKey.roadNameKey] as? String {
            title = roadName
        }
        
        if let location = notification.userInfo?[PassiveLocationDataSource.NotificationUserInfoKey.locationKey] as? CLLocation {
            if trackPolyline == nil {
                trackPolyline = MGLPolyline()
            }
            
            var coordinates: [CLLocationCoordinate2D] = [location.coordinate]
            trackPolyline?.appendCoordinates(&coordinates, count: UInt(coordinates.count))
        }
        
        if let rawLocation = notification.userInfo?[PassiveLocationDataSource.NotificationUserInfoKey.rawLocationKey] as? CLLocation {
            if rawTrackPolyline == nil {
                rawTrackPolyline = MGLPolyline()
            }
            
            var coordinates: [CLLocationCoordinate2D] = [rawLocation.coordinate]
            rawTrackPolyline?.appendCoordinates(&coordinates, count: UInt(coordinates.count))
        }
        
        mapView?.addAnnotations([rawTrackPolyline!, trackPolyline!])
    }
}
