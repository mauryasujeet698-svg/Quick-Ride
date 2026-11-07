enum QuickRideBusinessModel {
  subscription,
  commission,
  hybrid;
}

enum QuickRideRideStatus {
  requested,
  searching,
  offered,
  accepted,
  driverArriving,
  arrived,
  inProgress,
  completed,
  cancelled;

  String get apiValue => switch (this) {
        QuickRideRideStatus.driverArriving => 'driver_arriving',
        QuickRideRideStatus.inProgress => 'in_progress',
        _ => name,
      };
}
