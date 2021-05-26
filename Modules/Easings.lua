local Easings = {}

function Easings.EaseOutCubic(x)
    return 1 - math.pow(1 - x, 3);
end
function Easings.EaseInOutCubic(x)
    return x < 0.5 and 4 * x * x * x or 1 - math.pow(-2 * x + 2, 3) / 2
end
function Easings.EaseOutCirc(x)
    return math.sqrt(1 - math.pow(x - 1, 2));
end
function Easings.EaseOutSine(x)
  return math.sin((x * math.pi) / 2);
end
function Easings.EaseInCirc(x)
    return 1 - math.sqrt(1 - math.pow(x, 2));
end
function Easings.EaseInOutCirc(x)
    return x < 0.5
    and (1 - math.sqrt(1 - math.pow(2 * x, 2))) / 2
    or (math.sqrt(1 - math.pow(-2 * x + 2, 2)) + 1) / 2;
end

return Easings
