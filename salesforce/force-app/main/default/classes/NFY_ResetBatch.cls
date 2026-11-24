/**
 * Removes demo transactions in dependency order, one slice per batch execute. since = null removes
 * every demo transaction; a datetime removes only what scenes created after it (quick reset).
 * Reference data (systems, flows, warehouses, products, GL accounts) stays. Run with scope 1:
 *   Database.executeBatch(new NFY_ResetBatch(null), 1);
 */
public without sharing class NFY_ResetBatch implements Database.Batchable<String>, Database.Stateful {
    Datetime since;
    Set<Integer> finished = new Set<Integer>();
    public NFY_ResetBatch(Datetime since) {
        this.since = since;
    }
    public Iterable<String> start(Database.BatchableContext ctx) {
        List<String> slices = new List<String>();
        for (Integer step = 0; step <= NFY_DemoData.LAST_STEP; step++) {
            // Enough slices per step for the full seed; empty slices return at once.
            Integer repeats = step == 7 ? 12 : (step == 10 ? 3 : 8);
            for (Integer k = 0; k < repeats; k++) {
                slices.add(step + ':' + k);
            }
        }
        return slices;
    }
    public void execute(Database.BatchableContext ctx, List<String> scope) {
        for (String slice : scope) {
            Integer step = Integer.valueOf(slice.substringBefore(':'));
            if (!finished.contains(step) && !NFY_DemoData.runStep(step, since)) {
                finished.add(step);
            }
        }
    }
    public void finish(Database.BatchableContext ctx) {
        System.debug('NFY reset finished');
    }
}