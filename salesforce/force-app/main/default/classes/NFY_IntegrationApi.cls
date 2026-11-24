/**
 * REST entry point Workato recipes call: POST /services/apexrest/nfinity/v1/events
 *   { "event": "order.upsert", "source": "SHOPIFY", "jobId": "j-123", "payload": { ... } }
 * payload may be the JSON object itself or that object as a JSON string.
 * Returns the sync log result. 200 for success or a skipped duplicate, 422 when processing failed
 * (the event is kept in the sync log and can be retried from Salesforce).
 */
@RestResource(urlMapping='/nfinity/v1/events')
global with sharing class NFY_IntegrationApi {

    @HttpPost
    global static void receive() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.request.requestBody.toString());
        } catch (Exception e) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => 'Body is not valid JSON.' }));
            return;
        }
        String eventType = (String) body.get('event');
        String source = (String) body.get('source');
        if (String.isBlank(eventType) || String.isBlank(source) || body.get('payload') == null) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'success' => false, 'message' => 'Send event, source and payload.' }));
            return;
        }
        // The payload may also arrive as a JSON string (a Workato formula such as {...}.to_json), which is passed on as is.
        Object payload = body.get('payload');
        String payloadJson = payload instanceof String ? (String) payload : JSON.serialize(payload);
        NFY_IntegrationService.Result r = NFY_IntegrationService.process(eventType, source, payloadJson,
            (String) body.get('jobId'), 'Workato');
        res.statusCode = r.success ? 200 : 422;
        res.responseBody = Blob.valueOf(JSON.serialize(r));
    }

    @HttpGet
    global static void health() {
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'status' => 'ok', 'events' => new List<String>(NFY_IntegrationService.EVENT_ENTITY.keySet()) }));
    }
}