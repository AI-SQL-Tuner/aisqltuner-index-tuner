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

CREATE OR ALTER PROCEDURE AIIndexTuner.usp_InvokeModel
    @SystemPrompt nvarchar(max),
    @UserPrompt   nvarchar(max),
    @Text         nvarchar(max) OUTPUT,
    @ModelUsed    nvarchar(128) OUTPUT,
    @InputTokens  int OUTPUT,
    @OutputTokens int OUTPUT,
    @Truncated    bit OUTPUT,
    @RawResponse  nvarchar(max) OUTPUT,
    @PollCount    int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PollCount = 0;

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

    -- Background mode: poll until the response leaves queued / in_progress.
    WHILE @Status IN ('queued', 'in_progress')
    BEGIN
        IF SYSDATETIME() >= @Deadline
        BEGIN
            SET @RawResponse = @Response;
            SET @Error = CONCAT(N'The AI response ', @ResponseId, N' was still ', @Status, N' after ', @MaxWaitSec,
                                N' seconds. Raise AIIndexTuner.Config.MaxWaitSec, lower ReasoningEffort, or narrow the scope.');
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
            THROW 50005, @Error, 1;
        END;

        SET @Status = JSON_VALUE(@Response, '$.result.status');
    END;

    SET @RawResponse = @Response;

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
