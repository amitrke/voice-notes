/// The text sizes the user can pick, as multiples of the normal size.
/// Applied on top of the system font size setting, so someone who already uses a
/// large system font can still go larger or smaller inside this app.
const textScaleSteps = <double>[0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

const defaultTextScale = 1.0;

/// The step closest to [value], so an old or hand-edited setting never lands
/// between two steps or outside the range.
double snapTextScale(double value) {
  var best = textScaleSteps.first;
  for (final s in textScaleSteps) {
    if ((s - value).abs() < (best - value).abs()) best = s;
  }
  return best;
}

String textScaleLabel(double scale) => '${(scale * 100).round()}%';
