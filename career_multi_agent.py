import os
import io
import uuid
import json
import requests
from typing import List, Optional

from fastapi import FastAPI, UploadFile, File, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from anthropic import Anthropic
from dotenv import load_dotenv
load_dotenv()

import pdfplumber
import docx  # python-docx

# ===================== CONFIG =====================

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
SERPAPI_API_KEY = os.getenv("SERPAPI_API_KEY")

# Use a model you already know works
ANTHROPIC_MODEL = "claude-3-haiku-20240307"

if not ANTHROPIC_API_KEY:
    print("⚠️  ANTHROPIC_API_KEY is not set. LLM endpoints will fail until you set it.")

if not SERPAPI_API_KEY:
    print("⚠️  SERPAPI_API_KEY is not set. Job search will fail until you set it.")

client = Anthropic(api_key=ANTHROPIC_API_KEY) if ANTHROPIC_API_KEY else None

# In-memory store: resume_id -> {"text": ..., "inferred_role": ..., "jobs": [...]}
RESUME_STORE = {}

# ===================== FASTAPI APP =====================

app = FastAPI(
    title="Career Multi-Agent System",
    description="Upload resume → infer role → fetch real jobs → tailor resume → interview guide → project ideas",
    version="0.3",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ===================== HELPERS =====================

def extract_text_from_file(upload: UploadFile) -> str:
    """Extract text from PDF or DOCX."""
    filename = upload.filename or ""
    content = upload.file.read()

    if filename.lower().endswith(".pdf"):
        with pdfplumber.open(io.BytesIO(content)) as pdf:
            pages = [page.extract_text() or "" for page in pdf.pages]
        text = "\n".join(pages)
    elif filename.lower().endswith((".docx", ".doc")):
        doc = docx.Document(io.BytesIO(content))
        text = "\n".join(p.text for p in doc.paragraphs)
    else:
        # Fallback: treat as plain text
        text = content.decode("utf-8", errors="ignore")

    text = text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Could not extract text from resume.")
    return text

def call_claude(prompt: str, max_tokens: int = 600) -> str:
    """Call Anthropic Claude with a simple user prompt."""
    if not client:
        raise HTTPException(status_code=500, detail="Anthropic client not initialized. Check ANTHROPIC_API_KEY.")
    try:
        resp = client.messages.create(
            model=ANTHROPIC_MODEL,
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": prompt}],
        )
        return resp.content[0].text.strip()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Claude API error: {e}")

def extract_job_role(resume_text: str) -> str:
    prompt = f"""
You are an expert career analyst.

Extract ONLY the user's REAL intended job role from the resume.
Return EXACTLY ONE job title. No extra text. No explanation.

Correct output examples:
Data Engineer
Marketing Manager
Teacher
Nurse
Software Developer
Sales Associate
Truck Driver
Business Analyst
HR Coordinator
Any valid single job role.

Resume:
{resume_text}

Return only ONE job role:
"""
    role = call_claude(prompt, max_tokens=20).strip()
    return role.split("\n")[0].strip()
  
# ===================== SCHEMAS =====================

class ResumeUploadResponse(BaseModel):
    resume_id: str
    inferred_role: str

class JobMatchRequest(BaseModel):
    resume_id: str
    location: Optional[str] = "United States" 

def fetch_real_jobs_from_serpapi(role: str, location: str = "United States", limit: int = 5) -> List[dict]:

    """Use SerpAPI + Google Jobs to get real recent jobs for ANY role."""
    if not SERPAPI_API_KEY:
        raise HTTPException(status_code=500, detail="SERPAPI_API_KEY not set. Cannot search jobs.")

    params = {
        "engine": "google_jobs",
        "q": role,
        "location": location,
        "hl": "en",
        "api_key": SERPAPI_API_KEY,
        "num": limit
    }

    try:
        r = requests.get("https://serpapi.com/search", params=params, timeout=20)
        data = r.json()

        if r.status_code != 200:
            raise HTTPException(
                status_code=500,
                detail=f"SerpAPI error {r.status_code}: {r.text[:500]}"
            )

        results = data.get("jobs_results", [])
        parsed = []

        for job in results[:limit]:
            cleaned = {
                "title": job.get("title", ""),
                "company": job.get("company_name", ""),
                "location": job.get("location", ""),
                "job_type": job.get("detected_extensions", {}).get("schedule_type", ""),
                "posted_at": job.get("detected_extensions", {}).get("posted_at", ""),
                "apply_link": job.get("apply_link", ""),
                "source_link": job.get("serpapi_link", "")
            }
            parsed.append(cleaned)

        return parsed

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"SerpAPI request failed: {str(e)}")

    location: Optional[str] = "United States"

class JobInfo(BaseModel):
    title: str
    company: Optional[str] = ""
    location: Optional[str] = ""
    job_type: Optional[str] = ""
    posted_at: Optional[str] = ""
    apply_link: Optional[str] = ""
    source_link: Optional[str] = ""

class JobMatchResponse(BaseModel):
    resume_id: str
    inferred_role: str
    jobs: List[JobInfo]

class JobSelectionRequest(BaseModel):
    resume_id: str
    job_index: int

class TailorResponse(BaseModel):
    tailored_resume: str

class InterviewResponse(BaseModel):
    interview_guide: str

class ProjectResponse(BaseModel):
    project_ideas: List[str]

# ===================== ENDPOINTS =====================

@app.post("/resume-agent", response_model=ResumeUploadResponse)
async def resume_agent(file: UploadFile = File(...)):
    """
    Agent 1:
    - Upload a resume (PDF, DOCX, or text)
    - Extract text
    - Infer target role using Claude (for ANY domain: teaching, marketing, sales, etc.)
    """
    text = extract_text_from_file(file)
    inferred_role = extract_job_role(text)

    resume_id = str(uuid.uuid4())
    RESUME_STORE[resume_id] = {
        "text": text,
        "inferred_role": inferred_role,
        "jobs": [],  # to be filled by job-match-agent
    }

    return ResumeUploadResponse(resume_id=resume_id, inferred_role=inferred_role)

@app.post("/job-match-agent", response_model=JobMatchResponse)
async def job_match_agent(req: JobMatchRequest):
    """
    Agent 2:
    - Takes resume_id (+ optional location)
    - Uses SerpAPI Google Jobs to fetch up to 5 real recent jobs for that inferred role
    - Works for ANY type of role (not just tech)
    """
    record = RESUME_STORE.get(req.resume_id)
    if not record:
        raise HTTPException(status_code=404, detail="Unknown resume_id")

    role = record["inferred_role"]
    jobs = fetch_real_jobs_from_serpapi(role=role, location=req.location or "United States", limit=5)
    record["jobs"] = jobs  # store in memory

    return JobMatchResponse(
        resume_id=req.resume_id,
        inferred_role=role,
        jobs=[JobInfo(**j) for j in jobs],
    )

@app.post("/tailor-agent", response_model=TailorResponse)
async def tailor_agent(req: JobSelectionRequest):
    """
    Agent 3:
    - Takes resume_id + job_index
    - Tailors the resume to that specific JD
    """
    record = RESUME_STORE.get(req.resume_id)
    if not record:
        raise HTTPException(status_code=404, detail="Unknown resume_id")

    jobs = record.get("jobs") or []
    if not (0 <= req.job_index < len(jobs)):
        raise HTTPException(status_code=400, detail="Invalid job_index")

    job = jobs[req.job_index]
    resume_text = record["text"]

    prompt = f"""
You are a resume optimization assistant.

Here is the original resume:

\"\"\"{resume_text[:8000]}\"\"\"

Here is the target job posting:

Title: {job.get('title')}
Company: {job.get('company')}
Location: {job.get('location')}
Job Type: {job.get('job_type')}
Description:
{job.get('description')}

TASK:
- Rewrite the resume so it is strongly tailored to this specific job.
- Maintain truthful content (don't invent fake experience).
- Emphasize the most relevant skills, tools, and outcomes.
- Keep it in clean resume format with sections (SUMMARY, SKILLS, EXPERIENCE, EDUCATION, PROJECTS if relevant).

Return ONLY the tailored resume text.
"""
    tailored = call_claude(prompt, max_tokens=1200)
    return TailorResponse(tailored_resume=tailored)

@app.post("/interview-agent", response_model=InterviewResponse)
async def interview_agent(req: JobSelectionRequest):
    """
    Agent 4:
    - Takes resume_id + job_index
    - Generates interview preparation guide for that role & company
    """
    record = RESUME_STORE.get(req.resume_id)
    if not record:
        raise HTTPException(status_code=404, detail="Unknown resume_id")

    jobs = record.get("jobs") or []
    if not (0 <= req.job_index < len(jobs)):
        raise HTTPException(status_code=400, detail="Invalid job_index")

    job = jobs[req.job_index]
    resume_text = record["text"]

    prompt = f"""
You are an interview coach.

Candidate resume:
\"\"\"{resume_text[:6000]}\"\"\"

Target job:
Title: {job.get('title')}
Company: {job.get('company')}
Location: {job.get('location')}
Job Type: {job.get('job_type')}
Description:
{job.get('description')}

TASK:
Create a detailed interview preparation guide that includes:
1. Key technical topics and concepts they MUST revise for this role.
2. 8–12 likely interview questions (technical + behavioral) tailored to:
   - this role
   - this company
   - the job type (full-time, internship, contract, etc.)
3. Brief suggestions on how this candidate should answer each question, referring to their background.
4. Any company-specific tips if possible (e.g., Amazon LPs, FAANG style, etc.).

Return in clean bullet-point / numbered format.
"""
    guide = call_claude(prompt, max_tokens=1000)
    return InterviewResponse(interview_guide=guide)

@app.post("/project-agent", response_model=ProjectResponse)
async def project_agent(req: JobSelectionRequest):
    """
    Agent 5:
    - Takes resume_id + job_index
    - Suggests 2–4 concrete project ideas + YouTube/course links
    """
    record = RESUME_STORE.get(req.resume_id)
    if not record:
        raise HTTPException(status_code=404, detail="Unknown resume_id")

    jobs = record.get("jobs") or []
    if not (0 <= req.job_index < len(jobs)):
        raise HTTPException(status_code=400, detail="Invalid job_index")

    job = jobs[req.job_index]
    role = record["inferred_role"]

    prompt = f"""
You are a project mentor.

Target role: {role}
Job title: {job.get('title')}
Company: {job.get('company')}
Description:
{job.get('description')}

TASK:
Suggest 3 very concrete portfolio project ideas this person can build to become a stronger candidate for THIS job.

For each project, include:
- Short project title
- What exactly they will build (very concrete)
- Key technologies/tools to use
- What kind of data or inputs
- What outputs / dashboards / APIs
- 1–2 relevant YouTube video or course suggestions (just plausible URLs; do not invent fake domains)

Return as a bullet list. 3 projects max.
"""
    ideas_text = call_claude(prompt, max_tokens=800)

    # For API we just treat each blank-line separated block as an idea
    ideas = [block.strip() for block in ideas_text.split("\n\n") if block.strip()]

    return ProjectResponse(project_ideas=ideas)

# =====================================================
# MAIN (for local testing)
# =====================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("career_multi_agent:app", host="127.0.0.1", port=8003, reload=True)
