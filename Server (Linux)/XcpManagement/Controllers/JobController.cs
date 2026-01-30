using Microsoft.AspNetCore.Mvc;
using XcpManagement.DTOs;
using XcpManagement.Services;

namespace XcpManagement.Controllers;

[ApiController]
[Route("api/[controller]")]
public class JobController : ControllerBase
{
    private readonly IJobService _jobService;
    private readonly ILogger<JobController> _logger;

    public JobController(IJobService jobService, ILogger<JobController> logger)
    {
        _jobService = jobService;
        _logger = logger;
    }

    [HttpPost]
    public async Task<ActionResult<string>> CreateJob([FromBody] CreateJobRequest request)
    {
        try
        {
            var jobId = await _jobService.CreateJobAsync(request);
            return Ok(new { jobId, message = "Job created successfully" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error creating job");
            return StatusCode(500, new { error = "Failed to create job" });
        }
    }

    [HttpPost("status")]
    public async Task<ActionResult> UpdateJobStatus([FromBody] JobStatusUpdateRequest request)
    {
        try
        {
            var result = await _jobService.UpdateJobStatusAsync(request);
            if (!result)
            {
                return NotFound(new { error = "Job not found" });
            }
            return Ok(new { message = "Job status updated" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error updating job status");
            return StatusCode(500, new { error = "Failed to update job status" });
        }
    }

    [HttpPost("result")]
    public async Task<ActionResult> UpdateJobResult([FromBody] JobResultRequest request)
    {
        try
        {
            var result = await _jobService.UpdateJobResultAsync(request);
            if (!result)
            {
                return NotFound(new { error = "Job not found" });
            }
            return Ok(new { message = "Job result updated" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error updating job result");
            return StatusCode(500, new { error = "Failed to update job result" });
        }
    }

    [HttpGet]
    public async Task<ActionResult<List<JobDetailDto>>> GetAllJobs([FromQuery] string? status = null)
    {
        try
        {
            var jobs = await _jobService.GetAllJobsAsync(status);
            return Ok(jobs);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving jobs");
            return StatusCode(500, new { error = "Failed to retrieve jobs" });
        }
    }

    [HttpGet("{jobId}")]
    public async Task<ActionResult<JobDetailDto>> GetJob(string jobId)
    {
        try
        {
            var job = await _jobService.GetJobAsync(jobId);
            if (job == null)
            {
                return NotFound(new { error = "Job not found" });
            }
            return Ok(job);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving job");
            return StatusCode(500, new { error = "Failed to retrieve job" });
        }
    }

    [HttpGet("agent/{agentId}")]
    public async Task<ActionResult<List<JobDetailDto>>> GetJobsByAgent(string agentId)
    {
        try
        {
            var jobs = await _jobService.GetJobsByAgentAsync(agentId);
            return Ok(jobs);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving agent jobs");
            return StatusCode(500, new { error = "Failed to retrieve agent jobs" });
        }
    }
}