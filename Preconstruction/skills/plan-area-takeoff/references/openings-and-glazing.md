# Doors, windows, glazing and hardware

Create a physical opening register linking plan tags, schedules, elevations, details and specifications. Keep opening ID distinct from type ID: a type schedule describes repeated instances, while multiple views of one opening are evidence for one instance.

## Required opening fields

Record location/level, source references, work disposition, opening type, assembly count, leaf/sash/panel configuration, dimensions and dimension basis, frame material, finish, glazing specification, documented ratings, hardware-set reference, responsibility, quantity IDs and unresolved questions. Preserve rough opening, frame/unit, leaf and clear opening dimensions separately; one does not substitute for another.

| Component | Quantity treatment |
|---|---|
| Opening / assembled unit | EA by physical occurrence |
| Door leaves / operable sash | EA from actual configuration, separate from opening count |
| Frames | EA or documented member LF; distinguish replacement from retained frames |
| Glass | Pane EA and sourced pane SF by type/thickness; retain unit-size proxy only as provisional |
| Hardware sets | Scheduled sets per applicable opening; components only from the set's actual contents |
| Trim / sills / returns | LF/SF from supported profiles, depths and treated faces |
| Flashing / sealants / finishes | Separate documented operations linked to the opening |

Reconcile each plan occurrence to its schedule and each schedule row to actual occurrences. An unlocated schedule type stays unquantified. Resolve repeated tags by location; flag conflicting tags/configurations instead of silently choosing one.

For one double-leaf opening with one specified hardware set, report one opening, two leaves and one set, even when it appears in several elevations. Do not multiply the set by leaves. Pair-specific items, hinges, closers, locks, access control and thresholds require the actual schedule; do not supply a generic kit.

## Glazing and installation interfaces

- Separate exterior windows, storefront/curtain wall, interior partitions, mirrors and shower enclosures by assembly and specification. Do not treat all transparent surfaces as the same glass product.
- Use documented glass pane sizes for fabrication SF. Overall window SF is not net glass SF. Insulating glass units and laminated assemblies remain units of the specified construction; multiplying faces is not automatically extra ordered glass.
- Separate operable shower doors from fixed panels, returns and supports. Tile exclusions and glass quantities may share a location but require their own dimensions and bases.
- Link retained, relocated and new units to demolition and restoration. Count removal, reinstallation and new procurement as distinct operations, with no replacement purchase inferred from relocation.
- Link supplied flashing, pan, backing, sealant and finish details. A perimeter supports a potential joint route, not a complete sealant cartridge order without joint section and product yield.

Flag missing handing, configuration, dimensions, glass type, ratings and hardware where they affect procurement. Do not infer compliance or required ratings from room use. Shop drawings and field dimensions may remain required before fabrication even when bid quantities are established.
