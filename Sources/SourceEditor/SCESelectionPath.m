#import "SCESelectionPath.h"
#import <math.h>

static const CGFloat SCECoordinateEpsilon = 1e-6;

typedef struct {
    NSUInteger startX;
    NSUInteger startY;
    NSUInteger endX;
    NSUInteger endY;
    BOOL visited;
} SCEBoundaryEdge;

static NSArray<NSNumber *> *SCEUniqueCoordinates(NSMutableArray<NSNumber *> *values) {
    [values sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *unique = [NSMutableArray arrayWithCapacity:values.count];
    for (NSNumber *value in values) {
        if (!unique.count || value.doubleValue - unique.lastObject.doubleValue > SCECoordinateEpsilon) {
            [unique addObject:value];
        }
    }
    return unique;
}

static NSUInteger SCECoordinateIndex(NSArray<NSNumber *> *coordinates, CGFloat value) {
    NSUInteger low = 0;
    NSUInteger high = coordinates.count;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (coordinates[mid].doubleValue < value) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low && (low == coordinates.count || fabs(coordinates[low - 1].doubleValue - value) <= SCECoordinateEpsilon)) {
        return low - 1;
    }
    return low;
}

// Ranges here index x coordinates, not text. Each band contains sorted, disjoint
// spans; no pixel grid or document-sized bitmap is needed to compute the union.
static NSArray<NSValue *> *SCEMergeSpans(NSMutableArray<NSValue *> *spans) {
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
        } else {
            [merged addObject:value];
        }
    }
    return merged;
}

static NSArray<NSValue *> *SCESubtractSpans(NSArray<NSValue *> *spans, NSArray<NSValue *> *covered) {
    NSMutableArray<NSValue *> *result = [NSMutableArray array];
    NSUInteger firstCover = 0;
    for (NSValue *value in spans) {
        NSRange span = value.rangeValue;
        NSUInteger cursor = span.location;
        NSUInteger end = NSMaxRange(span);
        while (firstCover < covered.count && NSMaxRange(covered[firstCover].rangeValue) <= cursor) {
            firstCover++;
        }
        for (NSUInteger i = firstCover; i < covered.count; i++) {
            NSRange mask = covered[i].rangeValue;
            if (mask.location >= end) {
                break;
            }
            if (mask.location > cursor) {
                [result addObject:[NSValue valueWithRange:NSMakeRange(cursor, mask.location - cursor)]];
            }
            cursor = MAX(cursor, NSMaxRange(mask));
            if (cursor >= end) {
                break;
            }
        }
        if (cursor < end) {
            [result addObject:[NSValue valueWithRange:NSMakeRange(cursor, end - cursor)]];
        }
    }
    return result;
}

static NSNumber *SCEVertexKey(NSUInteger x, NSUInteger y) {
    return @(((uint64_t)x << 32) | (uint64_t)y);
}

static void SCEAddEdge(NSMutableData *edges, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *outgoing,
                       NSUInteger x1, NSUInteger y1, NSUInteger x2, NSUInteger y2) {
    if (x1 == x2 && y1 == y2) {
        return;
    }
    NSUInteger index = edges.length / sizeof(SCEBoundaryEdge);
    SCEBoundaryEdge edge = {
        x1, y1, x2, y2, NO,
    };
    [edges appendBytes:&edge length:sizeof(edge)];
    NSNumber *key = SCEVertexKey(x1, y1);
    if (!outgoing[key]) {
        outgoing[key] = [NSMutableArray arrayWithCapacity:2];
    }
    [outgoing[key] addObject:@(index)];
}

// Directions are right, down, left, up in the editor's flipped coordinates.
static NSUInteger SCEEdgeDirection(SCEBoundaryEdge edge) {
    if (edge.endX > edge.startX) {
        return 0;
    }
    if (edge.endY > edge.startY) {
        return 1;
    }
    if (edge.endX < edge.startX) {
        return 2;
    }
    return 3;
}

static CGPoint SCEPointOffset(CGPoint point, CGPoint direction, CGFloat distance) {
    return CGPointMake(point.x + direction.x * distance, point.y + direction.y * distance);
}

static void SCEAppendRoundedContour(CGMutablePathRef path, NSArray<NSValue *> *points, CGFloat radius) {
    // Remove vertices introduced by band boundaries on an otherwise straight
    // edge. Only actual changes of direction should create a corner.
    NSMutableArray<NSValue *> *corners = [NSMutableArray arrayWithCapacity:points.count];
    for (NSUInteger i = 0; i < points.count; i++) {
        CGPoint previous = points[(i + points.count - 1) % points.count].pointValue;
        CGPoint current = points[i].pointValue;
        CGPoint next = points[(i + 1) % points.count].pointValue;
        if ((previous.x == current.x && current.x == next.x) || (previous.y == current.y && current.y == next.y)) {
            continue;
        }
        [corners addObject:points[i]];
    }
    if (corners.count < 4) {
        return;
    }
    for (NSUInteger i = 0; i < corners.count; i++) {
        CGPoint previous = corners[(i + corners.count - 1) % corners.count].pointValue;
        CGPoint vertex = corners[i].pointValue;
        CGPoint next = corners[(i + 1) % corners.count].pointValue;
        CGFloat incomingLength = hypot(vertex.x - previous.x, vertex.y - previous.y);
        CGFloat outgoingLength = hypot(next.x - vertex.x, next.y - vertex.y);
        CGPoint incoming =
            CGPointMake((vertex.x - previous.x) / incomingLength, (vertex.y - previous.y) / incomingLength);
        CGPoint outgoing = CGPointMake((next.x - vertex.x) / outgoingLength, (next.y - vertex.y) / outgoingLength);
        // The continuous-curvature transition extends beyond the corner radius.
        // Adjacent selection corners share short edges without overlapping.
        CGFloat extent = MIN(MAX(0, radius) * 1.5, MIN(incomingLength, outgoingLength) * 0.5);
        CGPoint entry = SCEPointOffset(vertex, incoming, -extent);
        CGPoint exit = SCEPointOffset(vertex, outgoing, extent);
        if (i == 0) {
            CGPathMoveToPoint(path, NULL, entry.x, entry.y);
        } else {
            CGPathAddLineToPoint(path, NULL, entry.x, entry.y);
        }
        if (extent == 0) {
            CGPathAddLineToPoint(path, NULL, vertex.x, vertex.y);
            continue;
        }
        // Both outer endpoints have zero curvature, matching their straight
        // edges. The two halves have equal first and second derivatives at
        // their midpoint, so curvature is continuous through the whole turn.
        CGPoint firstControl = SCEPointOffset(vertex, incoming, -0.64 * extent);
        CGPoint secondControl = SCEPointOffset(vertex, incoming, -0.32 * extent);
        CGPoint midpoint = SCEPointOffset(SCEPointOffset(vertex, incoming, -0.16 * extent), outgoing, 0.16 * extent);
        CGPathAddCurveToPoint(path, NULL, firstControl.x, firstControl.y, secondControl.x, secondControl.y, midpoint.x,
                              midpoint.y);
        firstControl = SCEPointOffset(vertex, outgoing, 0.32 * extent);
        secondControl = SCEPointOffset(vertex, outgoing, 0.64 * extent);
        CGPathAddCurveToPoint(path, NULL, firstControl.x, firstControl.y, secondControl.x, secondControl.y, exit.x,
                              exit.y);
    }
    CGPathCloseSubpath(path);
}

CGPathRef SCECreateSelectionPath(NSArray<NSValue *> *rectangles, CGFloat cornerRadius) {
    CGMutablePathRef path = CGPathCreateMutable();
    NSMutableArray<NSValue *> *validRects = [NSMutableArray arrayWithCapacity:rectangles.count];
    NSMutableArray<NSNumber *> *xValues = [NSMutableArray arrayWithCapacity:rectangles.count * 2];
    NSMutableArray<NSNumber *> *yValues = [NSMutableArray arrayWithCapacity:rectangles.count * 2];
    for (NSValue *value in rectangles) {
        CGRect rect = value.rectValue;
        if (CGRectIsEmpty(rect) || !isfinite(CGRectGetMinX(rect)) || !isfinite(CGRectGetMaxX(rect)) ||
            !isfinite(CGRectGetMinY(rect)) || !isfinite(CGRectGetMaxY(rect))) {
            continue;
        }
        [validRects addObject:value];
        [xValues addObject:@(CGRectGetMinX(rect))];
        [xValues addObject:@(CGRectGetMaxX(rect))];
        [yValues addObject:@(CGRectGetMinY(rect))];
        [yValues addObject:@(CGRectGetMaxY(rect))];
    }
    if (!validRects.count) {
        return path;
    }
    NSArray<NSNumber *> *xs = SCEUniqueCoordinates(xValues);
    NSArray<NSNumber *> *ys = SCEUniqueCoordinates(yValues);
    NSMutableArray<NSMutableArray<NSValue *> *> *rawBands = [NSMutableArray arrayWithCapacity:ys.count - 1];
    for (NSUInteger i = 1; i < ys.count; i++) {
        [rawBands addObject:[NSMutableArray array]];
    }
    for (NSValue *value in validRects) {
        CGRect rect = value.rectValue;
        NSUInteger left = SCECoordinateIndex(xs, CGRectGetMinX(rect));
        NSUInteger right = SCECoordinateIndex(xs, CGRectGetMaxX(rect));
        NSUInteger top = SCECoordinateIndex(ys, CGRectGetMinY(rect));
        NSUInteger bottom = SCECoordinateIndex(ys, CGRectGetMaxY(rect));
        if (right == left) {
            continue;
        }
        NSValue *span = [NSValue valueWithRange:NSMakeRange(left, right - left)];
        for (NSUInteger i = top; i < bottom; i++) {
            [rawBands[i] addObject:span];
        }
    }
    NSMutableArray<NSArray<NSValue *> *> *bands = [NSMutableArray arrayWithCapacity:rawBands.count];
    for (NSMutableArray<NSValue *> *band in rawBands) {
        [bands addObject:SCEMergeSpans(band)];
    }
    NSMutableData *edgeData = [NSMutableData data];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *outgoingEdges = [NSMutableDictionary dictionary];
    for (NSUInteger y = 0; y < bands.count; y++) {
        NSArray<NSValue *> *current = bands[y];
        NSArray<NSValue *> *above = y ? bands[y - 1] : @[];
        NSArray<NSValue *> *below = y + 1 < bands.count ? bands[y + 1] : @[];
        for (NSValue *value in current) {
            NSRange span = value.rangeValue;
            SCEAddEdge(edgeData, outgoingEdges, span.location, y + 1, span.location, y);
            SCEAddEdge(edgeData, outgoingEdges, NSMaxRange(span), y, NSMaxRange(span), y + 1);
        }
        for (NSValue *value in SCESubtractSpans(current, above)) {
            NSRange span = value.rangeValue;
            SCEAddEdge(edgeData, outgoingEdges, span.location, y, NSMaxRange(span), y);
        }
        for (NSValue *value in SCESubtractSpans(current, below)) {
            NSRange span = value.rangeValue;
            SCEAddEdge(edgeData, outgoingEdges, NSMaxRange(span), y + 1, span.location, y + 1);
        }
    }
    SCEBoundaryEdge *edges = edgeData.mutableBytes;
    NSUInteger edgeCount = edgeData.length / sizeof(SCEBoundaryEdge);
    for (NSUInteger start = 0; start < edgeCount; start++) {
        if (edges[start].visited) {
            continue;
        }
        NSMutableArray<NSValue *> *contour = [NSMutableArray array];
        NSUInteger index = start;
        BOOL closed = NO;
        for (NSUInteger step = 0; step < edgeCount; step++) {
            SCEBoundaryEdge *edge = &edges[index];
            edge->visited = YES;
            [contour addObject:[NSValue valueWithPoint:CGPointMake(xs[edge->startX].doubleValue,
                                                                   ys[edge->startY].doubleValue)]];
            if (edge->endX == edges[start].startX && edge->endY == edges[start].startY) {
                closed = YES;
                break;
            }
            NSUInteger next = NSNotFound;
            NSUInteger bestRank = NSUIntegerMax;
            NSUInteger incomingDirection = SCEEdgeDirection(*edge);
            for (NSNumber *candidate in outgoingEdges[SCEVertexKey(edge->endX, edge->endY)]) {
                NSUInteger candidateIndex = candidate.unsignedIntegerValue;
                if (edges[candidateIndex].visited) {
                    continue;
                }
                NSUInteger turn = (SCEEdgeDirection(edges[candidateIndex]) + 4 - incomingDirection) % 4;
                // At a diagonal point contact, preserve separate selection
                // contours to avoid self-intersection.
                NSUInteger rank = turn == 1 ? 0 : turn == 0 ? 1 : turn == 3 ? 2 : 3;
                if (rank < bestRank) {
                    next = candidateIndex;
                    bestRank = rank;
                }
            }
            if (next == NSNotFound) {
                break;
            }
            index = next;
        }
        if (closed) {
            SCEAppendRoundedContour(path, contour, cornerRadius);
        }
    }
    return path;
}
