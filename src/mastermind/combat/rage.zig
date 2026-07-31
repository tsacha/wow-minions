const rage_units_per_point: u32 = 10;

pub fn toPoints(raw_rage: u32) u32 {
    return raw_rage / rage_units_per_point;
}

pub fn fromPoints(points: u32) u32 {
    return points * rage_units_per_point;
}
