class AppConstants {
  static const String appName = 'bananafarm';
  static const String appVersion = '1.0.0';

  /// Public docker image deployed to every provider.
  static const String renderImage =
      'docker.io/subinkx/bananafarm-render:2.0.0';

  /// Fallback when the Blender addon doesn't report its version.
  ///
  /// Keep in step with the container's own two copies — `ENV BLENDER_VERSION`
  /// in `docker-image/Dockerfile` and the `-z` guard in
  /// `docker-image/entrypoint.sh`. They can't import this, so the only thing
  /// keeping them aligned is that all three name the same release.
  static const String defaultBlenderVersion = '5.2.2';

  /// Default cap on simultaneously running render jobs.
  static const int defaultMaxConcurrentJobs = 3;

  /// Where the render container fetches Blender from.
  ///
  /// This must stay byte-identical to the URL built in
  /// `docker-image/entrypoint.sh`, because the point of building it here is to
  /// check *that* URL before renting a GPU. If the two drift, the pre-flight
  /// starts approving downloads the container will then fail to make.
  ///
  /// Shape: `.../release/Blender<major>.<minor>/blender-<full>-linux-x64.tar.xz`
  static String blenderDownloadUrl(String version) {
    final parts = version.split('.');
    final series = parts.length >= 2 ? '${parts[0]}.${parts[1]}' : version;
    return 'https://download.blender.org/release/Blender$series'
        '/blender-$version-linux-x64.tar.xz';
  }
}
