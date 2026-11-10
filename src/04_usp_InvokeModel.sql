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

    DECLARE @rc int, @Response nvarchar(max), @HttpCode int, @Status varchar(30), @ResponseId nvarchar(200),
            @Deadline datetime2(0) = DATEADD(SECOND, @MaxWaitSec, SYSDATETIME()),
            @Delay char(8) = CONCAT('00:00:', RIGHT(CONCAT('0', @PollSec), 2)),
            @Error nvarchar(4000);

    -- AI request: Chars is the length of the request body.
    SET @LogLen = LEN(@Body);
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI request', @Chars = @Zero, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    EXEC @rc = sys.sp_invoke_external_rest_endpoint
        @url = @Url,
        @method = N'POST',
        @headers = N'{"Content-Type":"application/json"}',
        @payload = @Body,
        @credential = @Credential,
        @timeout = @Timeout,
        @response = @Response OUTPUT;

    SET @HttpCode = JSON_VALUE(@Response, '$.response.status.http.code');
    IF @rc <> 0 OR @HttpCode NOT BETWEEN 200 AND 299
    BEGIN
        SET @RawResponse = @Response;
        SET @Error = CONCAT(N'The AI endpoint returned HTTP ', @HttpCode, N': ',
                            ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000)));
        THROW 50003, @Error, 1;
    END;

    SELECT @Status = JSON_VALUE(@Response, '$.result.status'),
           @ResponseId = JSON_VALUE(@Response, '$.result.id');

    -- AI response: the wait for the answer (background mode polls); Chars is the length of the answer text.
    -- Message shows the polls so far while it waits.
    EXEC AIIndexTuner.usp_LogStep @Logging, @RunId, N'AI response', @Chars = @LogLen, @LogId = @LogId OUTPUT, @CharsAtStart = @LogChars OUTPUT;
    SET @LogChars = 0;

    -- Background mode: poll until the response leaves queued / in_progress.
    WHILE @Status IN ('queued', 'in_progress')
    BEGIN
        IF SYSDATETIME() >= @Deadline
        BEGIN
            SET @RawResponse = @Response;
            SET @Error = CONCAT(N'The AI response ', @ResponseId, N' was still ', @Status, N' after ', @MaxWaitSec,
                                N' seconds. Raise AIIndexTuner.Config.MaxWaitSec, lower ReasoningEffort, or narrow the scope.');
            -- Still running, so the delete may be refused; its outcome is recorded either way.
            EXEC AIIndexTuner.usp_DeleteResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;
            THROW 50004, @Error, 1;
        END;

        WAITFOR DELAY @Delay;
        SET @PollCount += 1;

        DECLARE @PollUrl nvarchar(4000) = CONCAT(@Url, N'/', @ResponseId);
        EXEC @rc = sys.sp_invoke_external_rest_endpoint
            @url = @PollUrl,
            @method = N'GET',
            @credential = @Credential,
            @timeout = @Timeout,
            @response = @Response OUTPUT;

        SET @HttpCode = JSON_VALUE(@Response, '$.response.status.http.code');
        IF @rc <> 0 OR @HttpCode NOT BETWEEN 200 AND 299
        BEGIN
            SET @RawResponse = @Response;
            SET @Error = CONCAT(N'Polling the AI response returned HTTP ', @HttpCode, N': ',
                                ISNULL(JSON_VALUE(@Response, '$.result.error.message'), LEFT(@Response, 2000)));
            EXEC AIIndexTuner.usp_DeleteResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;
            THROW 50005, @Error, 1;
        END;

        SET @Status = JSON_VALUE(@Response, '$.result.status');
        IF @Logging = 1
            UPDATE AIIndexTuner.RunLog SET Message = CONCAT(@PollCount, N' polls; status ', @Status) WHERE RunLogId = @LogId;
    END;

    SET @RawResponse = @Response;

    -- The answer is in hand (or the response ended without one), so the stored copy can go (issue #48).
    -- The Responses API stores every response by default, so this runs in background and foreground mode alike.
    EXEC AIIndexTuner.usp_DeleteResponse @Url, @ResponseId, @Credential, @Timeout, @RunId, @Logging;

    IF @Status IN ('failed', 'cancelled')
    BEGIN
        SET @Error = CONCAT(N'The AI response ', @Status, N': ', ISNULL(JSON_VALUE(@Response, '$.result.error.message'), N'(no message)'));
        THROW 50006, @Error, 1;
    END;

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
