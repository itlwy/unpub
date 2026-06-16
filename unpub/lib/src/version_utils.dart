import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:unpub/src/models.dart';

semver.Version parseVersion(String version) => semver.Version.parse(version);

semver.Version? tryParseVersion(String version) {
  try {
    return parseVersion(version);
  } catch (_) {
    return null;
  }
}

UnpubVersion primaryVersion(List<UnpubVersion> versions) {
  return versions.reduce((current, next) {
    final currentVersion = parseVersion(current.version);
    final nextVersion = parseVersion(next.version);
    return semver.Version.prioritize(nextVersion, currentVersion) > 0
        ? next
        : current;
  });
}

void sortVersionsByPriority(List<UnpubVersion> versions) {
  versions.sort((a, b) {
    return compareVersionPriority(a.version, b.version);
  });
}

int compareVersionPriority(String a, String b) {
  return semver.Version.prioritize(parseVersion(a), parseVersion(b));
}

int compareVersionPriorityDescending(String a, String b) {
  return compareVersionPriority(b, a);
}

bool matchesPrerelease(
  semver.Version version,
  semver.Version base,
  String tag,
) {
  return version.major == base.major &&
      version.minor == base.minor &&
      version.patch == base.patch &&
      version.build.isEmpty &&
      version.preRelease.isNotEmpty &&
      version.preRelease.first == tag;
}
