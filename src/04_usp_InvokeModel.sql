SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
/*
    AIIndexTuner.usp_InvokeModel

    Calls the customer's Azure OpenAI deployment through the Responses API
    (POST {endpoint}/openai/v1/responses) with sp_invoke_external_rest_endpoint, authenticated by
    the DATABASE SCOPED CREDENTIAL named in AIIndexTuner.Config.

    sp_invoke_external_rest_endpoint allows at most 230 seconds per call, which a reasoning model
    working through a large payload can exceed. With UseBackgroundMode = 1 the request is sent
    with "background": true, and the response is polled with GET .../responses/{id} until it
    completes or MaxWaitSec runs out.

    The Responses API stores every response for 30 days by default, prompt included. Once the answer
    is read, or the run gives up on it, the stored response is deleted (usp_DeleteResponse, issue #48).

    Transient failures (issue #50): a poll that fails with a network error, a timeout, or HTTP 408, 429,
    500, 502, 503 or 504 is retried up to 3 times, honouring Retry-After; the request itself only on
    429 and 503, which the endpoint returns before it starts a response (fn_RetryDelaySec). When the run
    gives up on a background response that is still queued or in progress (MaxWaitSec ran out, a poll
    kept failing), it is cancelled (usp_CancelResponse) before it is deleted, so it stops using tokens.
    A later call cannot pick up a response that finished after the deadline: it has been deleted.

    Only OpenAI models are supported for now.
*/
/* The Responses API request body. A function so the tests can check it without a network call. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_RequestBody
(
    @Deployment      nvarchar(128),
    @Effort          varchar(10),
    @MaxOutputTokens int,
    @Structured      bit,
    @Background      bit,
    @SystemPrompt    nvarchar(max),
    @UserPrompt      nvarchar(max)
)
RETURNS nvarchar(max)
AS
BEGIN
    -- GPT-4 and GPT-3.5 deployments are not reasoning models and reject reasoning.effort
    -- (same rule as ModelRequestSettings.OpenAiSupportsReasoningEffort).
    DECLARE @SendEffort bit = CASE WHEN @Deployment LIKE N'gpt-4%' OR @Deployment LIKE N'gpt-35%' OR @Deployment LIKE N'gpt-3.5%' THEN 0 ELSE 1 END;

    RETURN JSON_OBJECT(
        'model': @Deployment,
        'input': JSON_ARRAY(
            JSON_OBJECT('role': 'developer', 'content': @SystemPrompt),
            JSON_OBJECT('role': 'user', 'content': @UserPrompt)),
        'max_output_tokens': @MaxOutputTokens,
        -- JSON_QUERY outside the CASE: a CASE result is plain text, so JSON inside it would be
        -- escaped into a string.
        'reasoning': JSON_QUERY(CASE WHEN @SendEffort = 1 THEN JSON_OBJECT('effort': @Effort) END),
        'text': JSON_QUERY(CASE WHEN @Structured = 1 THEN JSON_OBJECT('format': JSON_OBJECT(
                    'type': 'json_schema',
                    'name': 'index_recommendations',
                    'strict': CAST(1 AS bit),
                    'schema': JSON_QUERY(AIIndexTuner.fn_ResponseSchema()))) END),
        'background': CASE WHEN @Background = 1 THEN CAST(1 AS bit) END,
        'store': CASE WHEN @Background = 1 THEN CAST(1 AS bit) END
        ABSENT ON NULL);
END;
GO

/* The answer text of a Responses API response as sp_invoke_external_rest_endpoint returns it
   ({"response": ..., "result": <the API response>}): every output_text block of every message
   item, in order. OPENJSON ... WITH (nvarchar(max)) because JSON_VALUE returns NULL past 4000
   characters, and the answer is longer than that. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_ResponseText(@Response nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN (
        SELECT STRING_AGG(c.[text], N'') WITHIN GROUP (ORDER BY CAST(o.[key] AS int), c.ordinal)
        FROM OPENJSON(@Response, '$.result.output') AS o
        CROSS APPLY (SELECT CAST(ci.[key] AS int) AS ordinal, ct.[type], ct.[text]
                     FROM OPENJSON(o.value, '$.content') AS ci
                     CROSS APPLY OPENJSON(ci.value) WITH ([type] varchar(50) '$.type', [text] nvarchar(max) '$.text') AS ct) AS c
        WHERE JSON_VALUE(o.value, '$.type') = 'message'
          AND c.[type] = 'output_text');
END;
GO

/* Deletes a response the endpoint stored (issue #48): DELETE {endpoint}/openai/v1/responses/{id}.
   The Responses API keeps every response for 30 days by default, background ones included, and a
   stored response holds the whole prompt (the collected diagnostics) and the answer. Never throws:
   a failed delete must not cost the run its answer. The outcome goes on the run row
   (StoredResponseId, StoredResponseDeleted) and, with logging on, the reason into AIIndexTuner.RunLog. */
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_DeleteResponse
    @Url        nvarchar(4000),   -- {endpoint}/openai/v1/responses
    @ResponseId nvarchar(200),
    @Credential sysname,
    @Timeout    smallint,
    @RunId      int = NULL,
    @Logging    bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@ResponseId), N'') IS NULL RETURN;

    DECLARE @rc int, @Response nvarchar(max), @HttpCode int, @Deleted bit = 0, @Message nvarchar(4000),
            @DeleteUrl nvarchar(4000) = CONCAT(@Url, N'/', @ResponseId),
            @LogId int, @LogRow int, @LogChars int, @Zero int = 0;

    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI response delete', @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    SET @LogRow = @LogId;

    BEGIN TRY
        EXEC @rc = sys.sp_invoke_external_rest_endpoint
            @url = @DeleteUrl,
            @method = N'DELETE',
            @credential = @Credential,
            @timeout = @Timeout,
            @response = @Response OUTPUT;

        SET @HttpCode = JSON_VALUE(@Response, '$.response.status.http.code');
        IF @rc = 0 AND @HttpCode BETWEEN 200 AND 299
            SELECT @Deleted = 1, @Message = CONCAT(N'Deleted stored response ', @ResponseId, N'.');
        ELSE
            SET @Message = CONCAT(N'Could not delete stored response ', @ResponseId, N': HTTP ', @HttpCode, N': ',
                                  ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000)));
    END TRY
    BEGIN CATCH
        SET @Message = CONCAT(N'Could not delete stored response ', @ResponseId, N': ', ERROR_MESSAGE());
    END CATCH;

    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    IF @Logging = 1
        UPDATE AIIndexTuner.RunLog SET Message = LEFT(@Message, 4000) WHERE RunLogId = @LogRow;

    IF @RunId IS NOT NULL
        UPDATE AIIndexTuner.Run SET StoredResponseId = LEFT(@ResponseId, 200), StoredResponseDeleted = @Deleted WHERE RunId = @RunId;
END;
GO

/* How long to wait before retrying a call to the endpoint that failed, in seconds, or NULL to fail now
   (issue #50). @HttpCode NULL = no HTTP response: a network error or a timeout. A poll (GET) is retried
   on that and on HTTP 408, 429, 500, 502, 503 and 504. The request (POST) only on 429 and 503, which the
   endpoint returns before it starts a response, so a retry cannot start, and bill, a second one.
   @Attempt is the retry about to be made, from 1; there are at most 3. The wait is the one the response
   asks for (Retry-After in seconds, or retry-after-ms / x-ms-retry-after-ms) and otherwise 2, 4 and 8
   seconds. A response that asks for more than 60 seconds is not retried: a run should not sit that long.
   Header names are lower-cased under a fixed collation (see fn_LevelRank). */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_RetryDelaySec(@Method varchar(10), @HttpCode int, @Response nvarchar(max), @Attempt int)
RETURNS int
AS
BEGIN
    IF @Attempt IS NULL OR @Attempt NOT BETWEEN 1 AND 3 RETURN NULL;
    IF NOT (   (@Method = 'GET'  AND (@HttpCode IS NULL OR @HttpCode IN (408, 429, 500, 502, 503, 504)))
            OR (@Method = 'POST' AND ISNULL(@HttpCode, 0) IN (429, 503)))
        RETURN NULL;

    DECLARE @Asked decimal(18, 3);
    IF ISJSON(@Response) = 1
        SELECT @Asked = MAX(CASE LOWER(h.[key] COLLATE Latin1_General_100_BIN2)
                                WHEN N'retry-after-ms'      THEN TRY_CAST(h.[value] AS decimal(18, 3)) / 1000
                                WHEN N'x-ms-retry-after-ms' THEN TRY_CAST(h.[value] AS decimal(18, 3)) / 1000
                                WHEN N'retry-after'         THEN TRY_CAST(h.[value] AS decimal(18, 3)) END)
        FROM OPENJSON(@Response, '$.response.headers') AS h;

    IF @Asked > 60 RETURN NULL;
    RETURN CASE WHEN @Asked > 0 THEN CAST(CEILING(@Asked) AS int) ELSE POWER(2, @Attempt) END;
END;
GO

/* Why a response that ended has no usable answer, or NULL (issue #50): failed, cancelled, or incomplete
   for a reason other than max_output_tokens (which is reported as Truncated). An incomplete response
   used to fall through to "did not return the expected JSON", hiding a content filter. */
CREATE OR ALTER FUNCTION AIIndexTuner.fn_ResponseError(@Response nvarchar(max))
RETURNS nvarchar(4000)
AS
BEGIN
    IF ISJSON(@Response) = 0 RETURN NULL;
    DECLARE @Status varchar(30) = JSON_VALUE(@Response, '$.result.status'),
            @Reason nvarchar(400) = JSON_VALUE(@Response, '$.result.incomplete_details.reason');

    RETURN CASE
        WHEN @Status IN ('failed', 'cancelled')
            THEN CONCAT(N'The AI response ', @Status, N': ', ISNULL(JSON_VALUE(@Response, '$.result.error.message'), N'(no message)'))
        WHEN @Status = 'incomplete' AND ISNULL(@Reason, N'') <> N'max_output_tokens'
            THEN CONCAT(N'The AI response is incomplete: ', ISNULL(@Reason, N'(no reason given)'),
                        CASE WHEN @Reason = N'content_filter' THEN N'. The deployment''s content filter stopped the answer.' ELSE N'.' END)
        END;
END;
GO

/* One call to the endpoint, retried on a transient failure as fn_RetryDelaySec says (issue #50). Never
   throws: @Ok = 1 for a 2xx answer. Otherwise @Response holds the last answer, always as JSON: an error
   raised by sp_invoke_external_rest_endpoint (no HTTP response), or an answer that is not JSON, is put in
   {"result": {"error": {"message": ...}}}. @Retries returns the retries made; one that would end after
   @Deadline is not made. */
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_CallEndpoint
    @Url        nvarchar(4000),
    @Method     varchar(10),
    @Payload    nvarchar(max) = NULL,
    @Credential sysname,
    @Timeout    smallint,
    @Deadline   datetime2(0) = NULL,
    @Response   nvarchar(max) = NULL OUTPUT,
    @HttpCode   int = NULL OUTPUT,
    @Ok         bit = 0 OUTPUT,
    @Retries    int = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @rc int, @Wait int, @Delay char(8), @HttpMethod nvarchar(6) = @Method;
    SELECT @Retries = 0, @Ok = 0;

    WHILE 1 = 1
    BEGIN
        SELECT @rc = NULL, @Response = NULL, @HttpCode = NULL;
        BEGIN TRY
            IF @Payload IS NULL
                EXEC @rc = sys.sp_invoke_external_rest_endpoint
                    @url = @Url, @method = @HttpMethod, @credential = @Credential, @timeout = @Timeout,
                    @response = @Response OUTPUT;
            ELSE
                EXEC @rc = sys.sp_invoke_external_rest_endpoint
                    @url = @Url, @method = @HttpMethod, @headers = N'{"Content-Type":"application/json"}', @payload = @Payload,
                    @credential = @Credential, @timeout = @Timeout, @response = @Response OUTPUT;

            IF ISJSON(@Response) = 1
                SET @HttpCode = TRY_CAST(JSON_VALUE(@Response, '$.response.status.http.code') AS int);
            ELSE
                SET @Response = JSON_OBJECT('result': JSON_OBJECT('error': JSON_OBJECT('message': LEFT(ISNULL(@Response, N'(empty response)'), 2000))));
        END TRY
        BEGIN CATCH
            SELECT @rc = NULL, @HttpCode = NULL,
                   @Response = JSON_OBJECT('result': JSON_OBJECT('error': JSON_OBJECT('message': CONCAT(N'Msg ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()))));
        END CATCH;

        IF @rc = 0 AND @HttpCode BETWEEN 200 AND 299
        BEGIN
            SET @Ok = 1;
            RETURN;
        END;

        SET @Wait = AIIndexTuner.fn_RetryDelaySec(@Method, @HttpCode, @Response, @Retries + 1);
        IF @Wait IS NULL OR DATEADD(SECOND, @Wait, SYSDATETIME()) > @Deadline
            RETURN;
        SET @Delay = CONVERT(char(8), DATEADD(SECOND, @Wait, CAST('00:00:00' AS time(0))), 108);
        WAITFOR DELAY @Delay;
        SET @Retries += 1;
    END;
END;
GO

/* Cancels a background response that is still queued or in progress (issue #50):
   POST {endpoint}/openai/v1/responses/{id}/cancel. Without it a response the run gave up on keeps running
   on the endpoint, using tokens nobody reads. Never throws; with logging on, the outcome goes into
   AIIndexTuner.RunLog. */
CREATE OR ALTER PROCEDURE AIIndexTuner.usp_CancelResponse
    @Url        nvarchar(4000),   -- {endpoint}/openai/v1/responses
    @ResponseId nvarchar(200),
    @Credential sysname,
    @Timeout    smallint,
    @RunId      int = NULL,
    @Logging    bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF NULLIF(LTRIM(@ResponseId), N'') IS NULL RETURN;

    DECLARE @Response nvarchar(max), @HttpCode int, @Ok bit, @Message nvarchar(4000),
            @CancelUrl nvarchar(4000) = CONCAT(@Url, N'/', @ResponseId, N'/cancel'),
            @LogId int, @LogRow int, @LogChars int, @Zero int = 0;

    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI response cancel', @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    SET @LogRow = @LogId;

    EXEC AIIndexTuner.usp_CallEndpoint @Url = @CancelUrl, @Method = 'POST', @Credential = @Credential, @Timeout = @Timeout,
         @Response = @Response OUTPUT, @HttpCode = @HttpCode OUTPUT, @Ok = @Ok OUTPUT;

    SET @Message = CASE WHEN @Ok = 1 THEN CONCAT(N'Cancelled response ', @ResponseId, N'.')
                        ELSE CONCAT(N'Could not cancel response ', @ResponseId, N': HTTP ', COALESCE(CAST(@HttpCode AS nvarchar(10)), N'(no response)'), N': ',
                                    ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000))) END;

    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    IF @Logging = 1
        UPDATE AIIndexTuner.RunLog SET Message = LEFT(@Message, 4000) WHERE RunLogId = @LogRow;
END;
GO

CREATE OR ALTER PROCEDURE AIIndexTuner.usp_InvokeModel
    @SystemPrompt nvarchar(max),
    @UserPrompt   nvarchar(max),
    @Text         nvarchar(max) OUTPUT,
    @ModelUsed    nvarchar(128) OUTPUT,
    @InputTokens  int OUTPUT,
    @OutputTokens int OUTPUT,
    @Truncated    bit OUTPUT,
    @RawResponse  nvarchar(max) OUTPUT,
    @PollCount    int = NULL OUTPUT,
    @RunId        int = NULL,   -- for AIIndexTuner.RunLog
    @Logging      bit = 0       -- 1 = log the request and the wait for the answer (issue #38)
AS
BEGIN
    SET NOCOUNT ON;
    SET @PollCount = 0;
    DECLARE @LogId int, @LogChars int, @Zero int = 0, @LogLen int;

    DECLARE @Endpoint nvarchar(400), @Deployment nvarchar(128), @Credential sysname, @Effort varchar(10),
            @MaxOutputTokens int, @Timeout smallint, @Background bit, @MaxWaitSec int, @PollSec tinyint,
            @Structured bit;

    SELECT @Endpoint = Endpoint, @Deployment = Deployment, @Credential = CredentialName, @Effort = ReasoningEffort,
           @MaxOutputTokens = MaxOutputTokens, @Timeout = RequestTimeoutSec, @Background = UseBackgroundMode,
           @MaxWaitSec = MaxWaitSec, @PollSec = PollIntervalSec, @Structured = UseStructuredOutput
    FROM AIIndexTuner.Config
    WHERE ConfigId = 1;

    IF @Endpoint IS NULL
        THROW 50001, N'AIIndexTuner.Config has no row. Run setup/Configure-Endpoint.sql first.', 1;

    IF @Deployment LIKE N'claude-%'
        THROW 50002, N'Claude deployments are not supported yet; configure an Azure OpenAI deployment.', 1;

    DECLARE @Url nvarchar(4000) = CONCAT(
        CASE WHEN RIGHT(@Endpoint, 1) = N'/' THEN LEFT(@Endpoint, LEN(@Endpoint) - 1) ELSE @Endpoint END,
        N'/openai/v1/responses');

    DECLARE @Body nvarchar(max) = AIIndexTuner.fn_RequestBody(@Deployment, @Effort, @MaxOutputTokens, @Structured, @Background, @SystemPrompt, @UserPrompt);

    DECLARE @Response nvarchar(max), @HttpCode int, @Ok bit, @Retries int, @PollRetries int = 0,
            @Status varchar(30), @ResponseId nvarchar(200), @PollUrl nvarchar(4000),
            @Deadline datetime2(0) = DATEADD(SECOND, @MaxWaitSec, SYSDATETIME()),
            @Delay char(8) = CONCAT('00:00:', RIGHT(CONCAT('0', @PollSec), 2)),
            @Error nvarchar(4000);

    -- AI request: Chars is the length of the request body. Retried only on HTTP 429 and 503 (issue #50).
    SET @LogLen = LEN(@Body);
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI request', @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    EXEC AIIndexTuner.usp_CallEndpoint @Url = @Url, @Method = 'POST', @Payload = @Body, @Credential = @Credential, @Timeout = @Timeout,
         @Deadline = @Deadline, @Response = @Response OUTPUT, @HttpCode = @HttpCode OUTPUT, @Ok = @Ok OUTPUT, @Retries = @Retries OUTPUT;
    IF @Logging = 1 AND @Retries > 0
        UPDATE AIIndexTuner.RunLog SET Message = CONCAT(@Retries, N' retries after HTTP 429 or 503') WHERE RunLogId = @LogId;

    IF @Ok = 0
    BEGIN
        SET @RawResponse = @Response;
        SET @Error = CONCAT(N'The AI endpoint returned HTTP ', COALESCE(CAST(@HttpCode AS nvarchar(10)), N'(no response)'), N': ',
                            ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000)),
                            CASE WHEN @Retries > 0 THEN CONCAT(N' (after ', @Retries, N' retries)') END);
        THROW 50003, @Error, 1;
    END;

    SELECT @Status = JSON_VALUE(@Response, '$.result.status'),
           @ResponseId = JSON_VALUE(@Response, '$.result.id');

    -- Recorded now, not only when it is deleted: a run that is killed while it waits leaves the id of the
    -- response it left behind (issue #50).
    IF @RunId IS NOT NULL AND @ResponseId IS NOT NULL
        UPDATE AIIndexTuner.Run SET StoredResponseId = LEFT(@ResponseId, 200) WHERE RunId = @RunId;

    -- AI response: the wait for the answer (background mode polls); Chars is the length of the answer text.
    -- Message shows the polls so far while it waits.
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI response', @Chars = @LogLen, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    SET @LogChars = 0;

    -- Background mode: poll until the response leaves queued / in_progress.
    BEGIN TRY
        WHILE @Status IN ('queued', 'in_progress')
        BEGIN
            IF SYSDATETIME() >= @Deadline
            BEGIN
                SET @Error = CONCAT(N'The AI response ', @ResponseId, N' was still ', @Status, N' after ', @MaxWaitSec,
                                    N' seconds, so the run gave up and asked the endpoint to cancel it. Raise AIIndexTuner.Config.MaxWaitSec, lower ReasoningEffort, or narrow the scope.');
                THROW 50004, @Error, 1;
            END;

            WAITFOR DELAY @Delay;
            SET @PollCount += 1;

            -- A transient failure is retried (up to 3 times, within the deadline) before the run gives up.
            SET @PollUrl = CONCAT(@Url, N'/', @ResponseId);
            EXEC AIIndexTuner.usp_CallEndpoint @Url = @PollUrl, @Method = 'GET', @Credential = @Credential, @Timeout = @Timeout,
                 @Deadline = @Deadline, @Response = @Response OUTPUT, @HttpCode = @HttpCode OUTPUT, @Ok = @Ok OUTPUT, @Retries = @Retries OUTPUT;
            SET @PollRetries += @Retries;

            IF @Ok = 0
            BEGIN
                SET @Error = CONCAT(N'Polling the AI response returned HTTP ', COALESCE(CAST(@HttpCode AS nvarchar(10)), N'(no response)'), N': ',
                                    ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000)),
                                    CASE WHEN @Retries > 0 THEN CONCAT(N' (after ', @Retries, N' retries)') END);
                THROW 50005, @Error, 1;
            END;

            SET @Status = JSON_VALUE(@Response, '$.result.status');
            IF @Logging = 1
                UPDATE AIIndexTuner.RunLog
                SET Message = CONCAT(@PollCount, N' polls; status ', @Status, CASE WHEN @PollRetries > 0 THEN CONCAT(N'; ', @PollRetries, N' retries') END)
                WHERE RunLogId = @LogId;
        END;
    END TRY
    BEGIN CATCH
        SET @RawResponse = @Response;
        -- The run is giving up on the response. @Status is the last one read, so one that may still be
        -- running is cancelled first, or it keeps using tokens (issue #50); then the stored copy is
        -- deleted (issue #48). Neither throws; their outcomes are recorded.
        IF @Status IN ('queued', 'in_progress')
            EXEC AIIndexTuner.usp_CancelResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;
        EXEC AIIndexTuner.usp_DeleteResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;
        THROW;
    END CATCH;

    SET @RawResponse = @Response;

    -- The answer is in hand (or the response ended without one), so the stored copy can go (issue #48).
    -- The Responses API stores every response by default, so this runs in background and foreground mode alike.
    EXEC AIIndexTuner.usp_DeleteResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;

    -- Failed, cancelled, or incomplete for another reason than the output token limit (issue #50).
    SET @Error = AIIndexTuner.fn_ResponseError(@Response);
    IF @Error IS NOT NULL
        THROW 50006, @Error, 1;

    SELECT @ModelUsed = JSON_VALUE(@Response, '$.result.model'),
           @InputTokens = JSON_VALUE(@Response, '$.result.usage.input_tokens'),
           @OutputTokens = JSON_VALUE(@Response, '$.result.usage.output_tokens'),
           @Truncated = CASE WHEN @Status = 'incomplete'
                              AND JSON_VALUE(@Response, '$.result.incomplete_details.reason') = 'max_output_tokens' THEN 1 ELSE 0 END;

    SET @Text = AIIndexTuner.fn_ResponseText(@Response);

    SET @LogLen = ISNULL(LEN(@Text), 0);
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, NULL, @Chars = @LogLen, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;

    IF @Text IS NULL
    BEGIN
        DECLARE @Refusal nvarchar(4000) = (
            SELECT TOP (1) JSON_VALUE(ci.value, '$.refusal')
            FROM OPENJSON(@Response, '$.result.output') AS o
            CROSS APPLY OPENJSON(o.value, '$.content') AS ci
            WHERE JSON_VALUE(ci.value, '$.type') = 'refusal');

        SET @Error = CASE WHEN @Refusal IS NOT NULL THEN CONCAT(N'The model refused: ', @Refusal)
                          WHEN @Truncated = 1 THEN N'The model ran out of output tokens before answering. Raise AIIndexTuner.Config.MaxOutputTokens or lower ReasoningEffort.'
                          ELSE N'The AI response contained no output text.' END;
        THROW 50007, @Error, 1;
    END;
END;
GO
