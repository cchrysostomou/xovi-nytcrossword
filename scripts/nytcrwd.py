import requests
import argparse
from datetime import datetime, timedelta
from pathlib import Path
from pypdf import PdfWriter, PdfReader
import os
import subprocess


def load_access_config(config_path: Path) -> dict[str, str]:
    settings = {}
    for number, line in enumerate(config_path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not key.isidentifier():
            raise ValueError(f"Invalid configuration entry on line {number}.")
        settings[key] = value.strip()

    cookie = settings.get("NYT_COOKIE", "")
    if not cookie and settings.get("NYT_S_COOKIE"):
        cookie = "NYT-S=" + settings["NYT_S_COOKIE"]
    if not cookie:
        raise ValueError("Set NYT_S_COOKIE or NYT_COOKIE in the local config file.")
    return {
        "cookie": cookie,
        "rmapi_path": settings.get("RMAPI_PATH") or "rmapi",
        "rmapi_folder": settings.get("RMAPI_FOLDER") or "/Crosswords",
    }


def _save_rmapi(date, pdf_file, prefix_path="/Crosswords", rmapi_path="rmapi"):
    year = date.strftime("%Y")
    outfolder = f"{prefix_path}/{year} CW"
    # make directory
    subprocess.run([rmapi_path, "mkdir", outfolder], check=True)
    # save file
    subprocess.run(
        [rmapi_path, "put", str(pdf_file), f"{outfolder}/", "--content-only"],
        check=True,
    )

def download_nyt_crossword(date, cookie: str, output_dir="."):
    """
    Download NYTimes crossword PDF for a given date.

    Args:
        date: Either a datetime object or string in format 'Jan0126' (MonDDYY)
        output_dir: Directory to save the PDF (default: current directory)

    Returns:
        Path to the downloaded PDF file

    Examples:
        # Using a datetime object
        download_nyt_crossword(datetime(2026, 1, 1))

        # Using a string
        download_nyt_crossword("Jan0126")

        # Specify output directory
        download_nyt_crossword(datetime.now(), output_dir="./crosswords")
    """
    # Format date string if datetime object is provided
    if isinstance(date, datetime):
        date_str = date.strftime("%b%d%y")  # e.g., "Jan0126"
    else:
        date_str = date

    # Construct URL
    url = f"https://www.nytimes.com/svc/crosswords/v2/puzzle/print/{date_str}.pdf"

    # Set up headers with cookie
    headers = {
        "Cookie": cookie,
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    # Download the PDF
    response = requests.get(url, headers=headers)
    response.raise_for_status()

    # Save the file
    output_path = Path(output_dir) / f"nyt_crossword_{date_str}.pdf"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, "wb") as f:
        f.write(response.content)

    print(f"Downloaded crossword to: {output_path}")
    return output_path


def download_multiple_crosswords(num_days,cookie: str, end_date=None, output_dir="."):
    """
    Download multiple NYTimes crosswords for a range of days.

    Args:
        num_days: Number of days of crosswords to download (going backwards from end_date)
        end_date: Last date to download (default: today). Can be datetime object or string
        output_dir: Directory to save the PDFs (default: current directory)

    Returns:
        List of paths to downloaded PDF files

    Examples:
        # Download last 7 days of crosswords (including today)
        download_multiple_crosswords(7)

        # Download 5 days ending on a specific date
        download_multiple_crosswords(5, datetime(2026, 1, 15))

        # Download with custom output directory
        download_multiple_crosswords(10, output_dir="./crosswords")
    """
    # Use today if no end_date specified
    if end_date is None:
        end_date = datetime.now()
    elif isinstance(end_date, str):
        # If string provided, try to parse it
        try:
            end_date = datetime.strptime(end_date, "%b%d%y")
        except ValueError:
            # Try other common formats
            end_date = datetime.strptime(end_date, "%Y-%m-%d")

    downloaded_files = []

    print(f"Downloading {num_days} crosswords ending on {end_date.strftime('%B %d, %Y')}")

    for i in range(num_days):
        # Calculate the date (going backwards from end_date)
        current_date = end_date - timedelta(days=i)

        try:
            file_path = download_nyt_crossword(current_date, cookie, output_dir)
            downloaded_files.append(file_path)
        except requests.exceptions.HTTPError as e:
            print(f"Failed to download crossword for {current_date.strftime('%b %d, %Y')}: {e}")
        except Exception as e:
            print(f"Error downloading {current_date.strftime('%b %d, %Y')}: {e}")

    print(f"\nSuccessfully downloaded {len(downloaded_files)} out of {num_days} crosswords")
    return downloaded_files


def merge_crossword_pdfs(pdf_files, output_filename="merged_crosswords.pdf", sort_by_date=True):
    """
    Merge multiple crossword PDF files into a single PDF.

    Args:
        pdf_files: List of paths to PDF files to merge
        output_filename: Name of the output merged PDF (default: "merged_crosswords.pdf")
        sort_by_date: Whether to sort PDFs by date before merging (default: True)

    Returns:
        Path to the merged PDF file

    Examples:
        # Merge a list of PDFs
        files = [Path("nyt_crossword_Jan0126.pdf"), Path("nyt_crossword_Jan0226.pdf")]
        merge_crossword_pdfs(files)

        # Merge with custom output name
        merge_crossword_pdfs(files, output_filename="january_crosswords.pdf")
    """
    if not pdf_files:
        print("No PDF files to merge")
        return None

    # Convert to Path objects and filter out non-existent files
    pdf_paths = [Path(f) for f in pdf_files if Path(f).exists()]

    if not pdf_paths:
        print("No valid PDF files found")
        return None

    # Sort by date if requested (extract date from filename)
    if sort_by_date:
        def extract_date(path):
            try:
                # Extract date string from filename like "nyt_crossword_Jan0126.pdf"
                date_str = path.stem.split("_")[-1]  # Get "Jan0126" part
                return datetime.strptime(date_str, "%b%d%y")
            except (ValueError, IndexError):
                return datetime.min  # Put unparseable files at the beginning

        pdf_paths.sort(key=extract_date)

    # Create PDF writer and merge files
    pdf_writer = PdfWriter()

    print(f"Merging {len(pdf_paths)} PDF files...")
    for pdf_path in pdf_paths:
        try:
            pdf_reader = PdfReader(str(pdf_path))
            for page in pdf_reader.pages:
                pdf_writer.add_page(page)
            print(f"  Added: {pdf_path.name}")
        except Exception as e:
            print(f"  Error reading {pdf_path.name}: {e}")

    # Write merged PDF
    output_path = Path(pdf_paths[0].parent) / output_filename
    with open(output_path, "wb") as output_file:
        pdf_writer.write(output_file)

    print(f"\nMerged PDF saved to: {output_path}")
    return output_path


def download_and_merge_crosswords(num_days, cookie: str, end_date=None, output_dir=".",
                                   merge=True, merged_filename=None):
    """
    Download multiple crosswords and optionally merge them into a single PDF.

    Args:
        num_days: Number of days of crosswords to download
        end_date: Last date to download (default: today)
        output_dir: Directory to save the PDFs (default: current directory)
        merge: Whether to merge PDFs after downloading (default: True)
        merged_filename: Name for merged PDF (default: auto-generated based on date range)

    Returns:
        Tuple of (list of downloaded files, path to merged PDF if merge=True else None)

    Examples:
        # Download and merge last 7 days
        download_and_merge_crosswords(7)

        # Download without merging
        download_and_merge_crosswords(5, merge=False)
    """
    # Download the crosswords
    downloaded_files = download_multiple_crosswords(num_days, cookie, end_date, output_dir)

    merged_path = None
    if merge and downloaded_files:
        # Generate default filename if not provided
        if merged_filename is None:
            end = end_date if end_date else datetime.now()
            start = end - timedelta(days=num_days-1)
            merged_filename = f"nyt_crosswords_{start.strftime('%b%d')}_to_{end.strftime('%b%d_%y')}.pdf"

        merged_path = merge_crossword_pdfs(downloaded_files, merged_filename)

    return downloaded_files, merged_path


def main():
    parser = argparse.ArgumentParser(description="Download and upload crossword PDFs.")
    parser.add_argument("num_days", nargs="?", type=int, default=7)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(os.environ.get(
            "NYTCROSSWORD_CONFIG", str(Path(__file__).resolve().parents[1] / "config.env")
        )),
    )
    arguments = parser.parse_args()
    if arguments.num_days < 1:
        parser.error("num_days must be at least 1.")
    try:
        settings = load_access_config(arguments.config)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Configuration error: {error}\n")
    num_days = arguments.num_days
    cookie = settings["cookie"]

    DELETE_FILES = True
    # Example usage: download today's crossword
    # download_nyt_crossword(datetime.now())

    # Download last 7 days of crosswords
    # download_multiple_crosswords(7)

    # Download and merge last 7 days
    ind_files, merged_path = download_and_merge_crosswords(num_days, cookie, output_dir=".", merged_filename=None)
    if merged_path is None:
        parser.exit(1, "No merged crossword PDF was produced; nothing to upload.\n")

    if DELETE_FILES:
        for file in ind_files:
            os.remove(file)
            print(f"Deleted individual file: {file}")
    # upload to rMAPI
    today = datetime.now()
    _save_rmapi(
        today, merged_path,
        prefix_path=settings["rmapi_folder"],
        rmapi_path=settings["rmapi_path"],
    )


if __name__ == "__main__":
    main()
