/**
 * Replays the history one event per batch execute (an order, then each of its shipments), the
 * way events really arrive. Run with scope 1:
 *   Database.executeBatch(new NFY_HistoryBatch(0, 120, 2), 1);
 * Orders from the last three days stay open; every eleventh order ships only partly.
 */
public without sharing class NFY_HistoryBatch implements Database.Batchable<String>, Database.Stateful {
    Integer first;
    Integer total;
    Integer maxPhase;
    public NFY_HistoryBatch(Integer first, Integer total, Integer maxPhase) {
        this.first = first;
        this.total = total;
        this.maxPhase = maxPhase;
    }
    public Iterable<String> start(Database.BatchableContext ctx) {
        List<String> steps = new List<String>();
        for (Integer i = first; i < total; i++) {
            for (Integer p = 0; p <= maxPhase; p++) {
                steps.add(i + ':' + p);
            }
        }
        return steps;
    }
    public void execute(Database.BatchableContext ctx, List<String> scope) {
        for (String step : scope) {
            NFY_DemoData.runHistoryStep(Integer.valueOf(step.substringBefore(':')), total, Integer.valueOf(step.substringAfter(':')));
        }
    }
    public void finish(Database.BatchableContext ctx) {
        System.debug('NFY history replay finished');
    }
}