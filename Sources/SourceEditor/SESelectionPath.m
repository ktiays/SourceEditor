#import "SESelectionPath.h"
#import <math.h>

static const CGFloat SECoordinateEpsilon = 1e-6;

typedef struct {
    NSUInteger startX;
    NSUInteger startY;
    NSUInteger endX;
    NSUInteger endY;
    BOOL visited;
} SEBoundaryEdge;

static NSArray<NSNumber *> *SEUniqueCoordinates(NSMutableArray<NSNumber *> *values) {
    [values sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *unique = [NSMutableArray arrayWithCapacity:values.count];
    for (NSNumber *value in values) {
        if (!unique.count || value.doubleValue - unique.lastObject.doubleValue > SECoordinateEpsilon)
            [unique addObject:value];
    }
    return unique;
}

static NSUInteger SECoordinateIndex(NSArray<NSNumber *> *coordinates, CGFloat value) {
    NSUInteger low = 0;
    NSUInteger high = coordinates.count;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (coordinates[mid].doubleValue < value)
            low = mid + 1;
        else
            high = mid;
    }
    if (low && (low == coordinates.count || fabs(coordinates[low - 1].doubleValue - value) <= SECoordinateEpsilon))
        return low - 1;
    return low;
}

// Ranges here index x coordinates, not text. Each band contains sorted, disjoint
// spans; no pixel grid or document-sized bitmap is needed to compute the union.
static NSArray<NSValue *> *SEMergeSpans(NSMutableArray<NSValue *> *spans) {
    [spans sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        NSUInteger lhs = a.rangeValue.location;
        NSUInteger rhs = b.rangeValue.location;
        return lhs < rhs ? NSOrderedAscending : lhs > rhs ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *merged = [NSMutableArray arrayWithCapacity:spans.count];
    for (NSValue *value in spans) {
        NSRange span = value.rangeValue;
        if (merged.count && span.location <= NSMaxRange(merged.lastObject.rangeValue)) {
            merged[merged.count - 1] = [NSValue valueWithRange:NSUnionRange(merged.lastObject.rangeValue, span)];
        } else
            [merged addObject:value];
    }
    return merged;
}

static NSArray<NSValue *> *SESubtractSpans(NSArray<NSValue *> *spans, NSArray<NSValue *> *covered) {
    NSMutableArray<NSValue *> *result = [NSMutableArray array];
    NSUInteger firstCover = 0;
    for (NSValue *value in spans) {
        NSRange span = value.rangeValue;
        NSUInteger cursor = span.location;
        NSUInteger end = NSMaxRange(span);
        while (firstCover < covered.count && NSMaxRange(covered[firstCover].rangeValue) <= cursor)
            firstCover++;
        for (NSUInteger i = firstCover; i < covered.count; i++) {
            NSRange mask = covered[i].rangeValue;
            if (mask.location >= end)
                break;
            if (mask.location > cursor)
                [result addObject:[NSValue valueWithRange:NSMakeRange(cursor, mask.location - cursor)]];
            cursor = MAX(cursor, NSMaxRange(mask));
            if (cursor >= end)
                break;
        }
        if (cursor < end)
            [result addObject:[NSValue valueWithRange:NSMakeRange(cursor, end - cursor)]];
    }
    return result;
}

static NSNumber *SEVertexKey(NSUInteger x, NSUInteger y) {
    return @(((uint64_t)x << 32) | (uint64_t)y);
}

static void SEAddEdge(NSMutableData *edges, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *outgoing,
    NSUInteger x1, NSUInteger y1, NSUInteger x2, NSUInteger y2) {
    if (x1 == x2 && y1 == y2)
        return;
    NSUInteger index = edges.length / sizeof(SEBoundaryEdge);
    SEBoundaryEdge edge = {
        x1,
        y1,
        x2,
        y2,
        NO,
    };
    [edges appendBytes:&edge length:sizeof(edge)];
    NSNumber *key = SEVertexKey(x1, y1);
    if (!outgoing[key])
        outgoing[key] = [NSMutableArray arrayWithCapacity:2];
    [outgoing[key] addObject:@(index)];
}

// Directions are right, down, left, up in the editor's flipped coordinates.
static NSUInteger SEEdgeDirection(SEBoundaryEdge edge) {
    if (edge.endX > edge.startX)
        return 0;
    if (edge.endY > edge.startY)
        return 1;
    if (edge.endX < edge.startX)
        return 2;
    return 3;
}

static CGPoint SEPointOffset(CGPoint point, CGPoint direction, CGFloat distance) {
    return CGPointMake(point.x + direction.x * distance, point.y + direction.y * distance);
}

static void SEAppendRoundedContour(CGMutablePathRef path, NSArray<NSValue *> *points, CGFloat radius) {
    // Remove vertices introduced by band boundaries on an otherwise straight
    // edge. Only actual changes of direction should create a corner.
    NSMutableArray<NSValue *> *corners = [NSMutableArray arrayWithCapacity:points.count];
    for (NSUInteger i = 0; i < points.count; i++) {
        CGPoint previous = points[(i + points.count - 1) % points.count].pointValue;
        CGPoint current = points[i].pointValue;
        CGPoint next = points[(i + 1) % points.count].pointValue;
        if ((previous.x == current.x && current.x == next.x) || (previous.y == current.y && current.y == next.y))
            continue;
        [corners addObject:points[i]];
    }
    if (corners.count < 4)
        return;
    for (NSUInteger i = 0; i < corners.count; i++) {
        CGPoint previous = corners[(i + corners.count - 1) % corners.count].pointValue;
        CGPoint vertex = corners[i].pointValue;
        CGPoint next = corners[(i + 1) % corners.count].pointValue;
        CGFloat incomingLength = hypot(vertex.x - previous.x, vertex.y - previous.y);
        CGFloat outgoingLength = hypot(next.x - vertex.x, next.y - vertex.y);
        CGPoint incoming
            = CGPointMake((vertex.x - previous.x) / incomingLength, (vertex.y - previous.y) / incomingLength);
        CGPoint outgoing = CGPointMake((next.x - vertex.x) / outgoingLength, (next.y - vertex.y) / outgoingLength);
        // The transition extends beyond a circular radius, as in a squircle.
        // Adjacent corners share each short edge without overlapping.
        CGFloat extent = MIN(MAX(0, radius) * 1.5, MIN(incomingLength, outgoingLength) * 0.5);
        CGPoint entry = SEPointOffset(vertex, incoming, -extent);
        CGPoint exit = SEPointOffset(vertex, outgoing, extent);
        if (i == 0)
            CGPathMoveToPoint(path, NULL, entry.x, entry.y);
        else
            CGPathAddLineToPoint(path, NULL, entry.x, entry.y);
        if (extent == 0) {
            CGPathAddLineToPoint(path, NULL, vertex.x, vertex.y);
            continue;
        }
        // Both outer endpoints have zero curvature, matching their straight
        // edges. The two halves have equal first AND second derivatives at
        // their midpoint, so curvature is continuous through the whole turn.
        CGPoint firstControl = SEPointOffset(vertex, incoming, -0.64 * extent);
        CGPoint secondControl = SEPointOffset(vertex, incoming, -0.32 * extent);
        CGPoint midpoint = SEPointOffset(SEPointOffset(vertex, incoming, -0.16 * extent), outgoing, 0.16 * extent);
        CGPathAddCurveToPoint(
            path, NULL, firstControl.x, firstControl.y, secondControl.x, secondControl.y, midpoint.x, midpoint.y);
        firstControl = SEPointOffset(vertex, outgoing, 0.32 * extent);
        secondControl = SEPointOffset(vertex, outgoing, 0.64 * extent);
        CGPathAddCurveToPoint(
            path, NULL, firstControl.x, firstControl.y, secondControl.x, secondControl.y, exit.x, exit.y);
    }
    CGPathCloseSubpath(path);
}

CGPathRef SECreateSelectionPath(NSArray<NSValue *> *rects, CGFloat cornerRadius) {
    CGMutablePathRef path = CGPathCreateMutable();
    NSMutableArray<NSValue *> *validRects = [NSMutableArray arrayWithCapacity:rects.count];
    NSMutableArray<NSNumber *> *xValues = [NSMutableArray arrayWithCapacity:rects.count * 2];
    NSMutableArray<NSNumber *> *yValues = [NSMutableArray arrayWithCapacity:rects.count * 2];
    for (NSValue *value in rects) {
        CGRect rect = value.rectValue;
        if (CGRectIsEmpty(rect) || !isfinite(CGRectGetMinX(rect)) || !isfinite(CGRectGetMaxX(rect))
            || !isfinite(CGRectGetMinY(rect)) || !isfinite(CGRectGetMaxY(rect)))
            continue;
        [validRects addObject:value];
        [xValues addObject:@(CGRectGetMinX(rect))];
        [xValues addObject:@(CGRectGetMaxX(rect))];
        [yValues addObject:@(CGRectGetMinY(rect))];
        [yValues addObject:@(CGRectGetMaxY(rect))];
    }
    if (!validRects.count)
        return path;
    NSArray<NSNumber *> *xs = SEUniqueCoordinates(xValues);
    NSArray<NSNumber *> *ys = SEUniqueCoordinates(yValues);
    NSMutableArray<NSMutableArray<NSValue *> *> *rawBands = [NSMutableArray arrayWithCapacity:ys.count - 1];
    for (NSUInteger i = 1; i < ys.count; i++)
        [rawBands addObject:[NSMutableArray array]];
    for (NSValue *value in validRects) {
        CGRect rect = value.rectValue;
        NSUInteger left = SECoordinateIndex(xs, CGRectGetMinX(rect));
        NSUInteger right = SECoordinateIndex(xs, CGRectGetMaxX(rect));
        NSUInteger top = SECoordinateIndex(ys, CGRectGetMinY(rect));
        NSUInteger bottom = SECoordinateIndex(ys, CGRectGetMaxY(rect));
        if (right == left)
            continue;
        NSValue *span = [NSValue valueWithRange:NSMakeRange(left, right - left)];
        for (NSUInteger i = top; i < bottom; i++)
            [rawBands[i] addObject:span];
    }
    NSMutableArray<NSArray<NSValue *> *> *bands = [NSMutableArray arrayWithCapacity:rawBands.count];
    for (NSMutableArray<NSValue *> *band in rawBands)
        [bands addObject:SEMergeSpans(band)];
    NSMutableData *edgeData = [NSMutableData data];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *outgoingEdges = [NSMutableDictionary dictionary];
    for (NSUInteger y = 0; y < bands.count; y++) {
        NSArray<NSValue *> *current = bands[y];
        NSArray<NSValue *> *above = y ? bands[y - 1] : @[];
        NSArray<NSValue *> *below = y + 1 < bands.count ? bands[y + 1] : @[];
        for (NSValue *value in current) {
            NSRange span = value.rangeValue;
            SEAddEdge(edgeData, outgoingEdges, span.location, y + 1, span.location, y);
            SEAddEdge(edgeData, outgoingEdges, NSMaxRange(span), y, NSMaxRange(span), y + 1);
        }
        for (NSValue *value in SESubtractSpans(current, above)) {
            NSRange span = value.rangeValue;
            SEAddEdge(edgeData, outgoingEdges, span.location, y, NSMaxRange(span), y);
        }
        for (NSValue *value in SESubtractSpans(current, below)) {
            NSRange span = value.rangeValue;
            SEAddEdge(edgeData, outgoingEdges, NSMaxRange(span), y + 1, span.location, y + 1);
        }
    }
    SEBoundaryEdge *edges = edgeData.mutableBytes;
    NSUInteger edgeCount = edgeData.length / sizeof(SEBoundaryEdge);
    for (NSUInteger start = 0; start < edgeCount; start++) {
        if (edges[start].visited)
            continue;
        NSMutableArray<NSValue *> *contour = [NSMutableArray array];
        NSUInteger index = start;
        BOOL closed = NO;
        for (NSUInteger step = 0; step < edgeCount; step++) {
            SEBoundaryEdge *edge = &edges[index];
            edge->visited = YES;
            [contour addObject:[NSValue valueWithPoint:CGPointMake(xs[edge->startX].doubleValue,
                                                           ys[edge->startY].doubleValue)]];
            if (edge->endX == edges[start].startX && edge->endY == edges[start].startY) {
                closed = YES;
                break;
            }
            NSUInteger next = NSNotFound;
            NSUInteger bestRank = NSUIntegerMax;
            NSUInteger incomingDirection = SEEdgeDirection(*edge);
            for (NSNumber *candidate in outgoingEdges[SEVertexKey(edge->endX, edge->endY)]) {
                NSUInteger candidateIndex = candidate.unsignedIntegerValue;
                if (edges[candidateIndex].visited)
                    continue;
                NSUInteger turn = (SEEdgeDirection(edges[candidateIndex]) + 4 - incomingDirection) % 4;
                // At a diagonal point contact, stay on the current component
                // instead of making a self-intersecting, welded contour.
                NSUInteger rank = turn == 1 ? 0 : turn == 0 ? 1 : turn == 3 ? 2 : 3;
                if (rank < bestRank) {
                    next = candidateIndex;
                    bestRank = rank;
                }
            }
            if (next == NSNotFound)
                break;
            index = next;
        }
        if (closed)
            SEAppendRoundedContour(path, contour, cornerRadius);
    }
    return path;
}
