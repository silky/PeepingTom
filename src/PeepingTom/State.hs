module PeepingTom.State (
    Candidate (..),
    PeepState (..),
    showState,
    applyFilter,
    updateState,
    applyWriter,
    scanMapS,
    scanMap,
) where

import Control.Exception
import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.List (intersperse, reverse)
import Data.List.Split (chunk)
import Data.Maybe (Maybe, catMaybes, mapMaybe)
import Debug.Trace
import qualified PeepingTom.Conversions as Conversions
import qualified PeepingTom.Filters as Filters
import qualified PeepingTom.IO as IO
import PeepingTom.Internal
import qualified PeepingTom.Maps as Maps
import qualified PeepingTom.Posix as Posix
import PeepingTom.Type
import qualified PeepingTom.Writer as Writer
import Text.Printf (printf)

-- Data types

data Candidate = Candidate
    { cAddress :: Address
    , cData :: BS.ByteString
    , cTypes :: [Type]
    , cRegionID :: Int
    }

data PeepState = PeepState
    { psPID :: PID
    , psCandidates :: [Candidate]
    , psRegions :: Maps.MapInfo
    }

instance Show Candidate where
    show candidate =
        printf
            "Address: 0x%08X\tData: [%s]\tPossible Types: %s\tRegion ID: %d"
            (cAddress $ candidate)
            (bsToString $ cData candidate)
            (show . cTypes $ candidate)
            (cRegionID candidate)

instance Show PeepState where
    show = showState 5 5

-- Private Methods

bsToString :: BS.ByteString -> String
bsToString bs = concat $ intersperse " " (fmap (printf "0x%02X") (BS.unpack bs))

showList :: (Show a) => [a] -> String
showList lst = concat $ intersperse "\n" (fmap show lst)

slice :: Address -> Address -> BS.ByteString -> BS.ByteString
slice start len = BS.take len . BS.drop start

vocal :: (a -> b -> IO ()) -> (a -> IO b) -> a -> (IO b)
vocal log action input = do
    output <- action input
    log input output
    return output

maxSizeOf :: [Type] -> Size
maxSizeOf types = foldr max 0 (map sizeOf types)

maxType :: [Type] -> Type
maxType [] = (Type Void)
maxType (t : rest)
    | sizeOf t < sizeOf (maxType rest) = (maxType rest)
    | otherwise = t

candidateFilter :: Filters.Filter -> Candidate -> Maybe Candidate
candidateFilter fltr candidate = output
  where
    bsData = cData $ candidate :: BS.ByteString
    valid_types = filter (fltr bsData) (cTypes candidate) :: [Type]
    output = if length valid_types == 0 then Nothing else candidate'
    max_size = maxSizeOf valid_types
    bsData' = BS.take max_size bsData -- Only store that amount of bytes
    candidate' = Just candidate{cData = bsData', cTypes = valid_types}

isInChunk :: Candidate -> IO.MemoryChunk -> Bool
isInChunk candidate chunk = (candidate_addr >= chunk_addr) && (candidate_addr + max_size <= chunk_addr + chunk_size)
  where
    candidate_addr = cAddress candidate
    candidate_types = cTypes candidate
    max_size = maxSizeOf candidate_types
    chunk_addr = IO.mcStartAddr chunk
    chunk_size = IO.mcSize chunk

filterChunk :: [Type] -> Filters.Filter -> Int -> IO.MemoryChunk -> Address -> Maybe Candidate
filterChunk types fltr regid chunk offset = output
  where
    address = (IO.mcStartAddr chunk) + offset
    bytes = BS.drop offset (IO.mcData chunk) -- Get all the bytes starting from offset
    candidate_types = filter (fltr bytes) types :: [Type]
    max_size = maxSizeOf candidate_types
    byte_data = BS.take max_size bytes -- Store this amount of bytes
    region_id = regid
    new_candidate =
        Candidate
            { cAddress = address
            , cData = byte_data
            , cTypes = candidate_types
            , cRegionID = region_id
            }
    output = if length candidate_types == 0 then Nothing else Just new_candidate

regionScanHelper :: IO.RInterface -> [Type] -> Filters.Filter -> Size -> (Address, Address) -> Int -> IO [Candidate]
regionScanHelper rinterface types fltr regid (start_address, end_address) chunk_size = do
    if start_address >= end_address
        then return []
        else do
            let max_size = maxSizeOf types
            let offset_size = min (end_address - start_address) chunk_size
            let read_size = min (end_address - start_address) (chunk_size + max_size)
            let offset = [0 .. offset_size]
            tail <- regionScanHelper rinterface types fltr regid (start_address + offset_size, end_address) chunk_size
            chunk <- rinterface start_address read_size
            let candidates = mapMaybe (filterChunk types fltr regid chunk) offset
            evaluate candidates
            return $ candidates ++ tail

regionScan :: [Type] -> Filters.Filter -> Maps.Region -> Size -> IO [Candidate]
regionScan types fltr region chunk_size = do
    let pid = Maps.rPID region
    let rid = Maps.rID region
    let sa = Maps.rStartAddr region
    let ea = Maps.rEndAddr region
    let action = (\rinterface -> regionScanHelper rinterface types fltr rid (sa, ea) chunk_size) :: IO.RInterface -> IO [Candidate]
    candidates <- IO.withRInterface pid action
    return candidates

regionScanLog :: Maps.Region -> [Candidate] -> IO ()
regionScanLog reg result = do
    if length result == 0 then return () else putStrLn $ printf "Extracted %4d candidates from Region %4d (size = %8x)" (length result) (Maps.rID reg) ((Maps.rEndAddr reg) - (Maps.rStartAddr reg))

scanMapHelper :: Size -> [Type] -> Filters.Filter -> Maps.MapInfo -> IO [Candidate]
scanMapHelper chunk_size types fltr map = do
    let regions = Maps.miRegions map
    let action = vocal regionScanLog (\x -> regionScan types fltr x chunk_size) :: Maps.Region -> IO [Candidate]
    fc <- forM regions action :: IO [[Candidate]]
    return $ concat fc

updateCandidatesHelper :: IO.RInterface -> [Candidate] -> IO.MemoryChunk -> IO [Candidate]
updateCandidatesHelper _ [] _ = return []
updateCandidatesHelper rinterface (current : rest) memory_chunk = do
    if (isInChunk current memory_chunk)
        then do
            let offset = (cAddress current) - (IO.mcStartAddr memory_chunk) -- Get the offset of the memory location in the bytestring corresponding to address
            let valid_types = cTypes current
            let byte_counts = map sizeOf valid_types
            let byte_count = foldl max 0 byte_counts
            let new_bytes = slice offset byte_count (IO.mcData memory_chunk)
            let new_candidate = current{cData = new_bytes}
            tail <- updateCandidatesHelper rinterface rest memory_chunk
            return $ [new_candidate] ++ tail
        else do
            let new_chunk_addr = cAddress current
            let chunk_size = IO.mcSize memory_chunk
            new_chunk <- rinterface new_chunk_addr chunk_size
            updateCandidatesHelper rinterface (current : rest) new_chunk

updateCandidates :: IO.RInterface -> Int -> [Candidate] -> IO [Candidate]
updateCandidates _ _ [] = return []
updateCandidates rinterface chunk_size candidates = do
    let initial = candidates !! 0
    let new_chunk_addr = cAddress initial
    chunk <- rinterface new_chunk_addr chunk_size
    updateCandidatesHelper rinterface candidates chunk

writeCandidate :: IO.WInterface -> Writer.Writer -> Candidate -> IO Candidate
writeCandidate winterface writer candidate = do
    let addr = cAddress candidate
    let maxtype = maxType . cTypes $ candidate -- Get the type with the largest size
    let bs_data = writer maxtype -- Get the bytes to write
    let data_size = BS.length bs_data
    if data_size == 0
        then return candidate -- Writer does not support this type; Don't write anything
        else do
            winterface addr bs_data
            let candidate' = candidate{cData = bs_data}
            return candidate'

applyWriterHelper :: IO.WInterface -> Writer.Writer -> [Candidate] -> IO [Candidate]
applyWriterHelper winterface writer candidates = sequence $ map (writeCandidate winterface writer) candidates

-- Public Methods

showState :: Int -> Int -> PeepState -> String
showState maxcandidates' maxregions' ps =
    printf "PID: %d\n" (psPID ps)
        ++ printf "Regions (%d): \n\n%s\n%s\n" (length . Maps.miRegions . psRegions $ ps) rstr rdot
        ++ printf "Candidates (%d): \n\n%s\n%s\n" (length . psCandidates $ ps) cstr cdot
  where
    maxcandidates = if maxcandidates < 0 then (length . psCandidates $ ps) else maxcandidates'
    maxregions = if maxregions' < 0 then (length . Maps.miRegions . psRegions $ ps) else maxregions'
    candidate_list = take maxcandidates (psCandidates ps)
    cstrlist = fmap show candidate_list
    cstr = concat $ intersperse "\n" cstrlist
    cdot = if (length . psCandidates $ ps) > maxcandidates then "...\n" else ""
    region_list = psRegions ps
    rstrlist = fmap show (take maxregions $ Maps.miRegions region_list)
    rstr = concat $ intersperse "\n" rstrlist
    rdot = if (length . Maps.miRegions $ region_list) > maxregions then "...\n" else ""

applyFilter :: Filters.Filter -> PeepState -> PeepState
applyFilter fltr state = output
  where
    candidates' = mapMaybe (candidateFilter fltr) (psCandidates state)
    output = state{psCandidates = candidates'}

updateState :: Size -> PeepState -> IO PeepState
updateState chunk_size state = do
    let pid = psPID state
    let candidates = psCandidates state
    let action = (\rinterface -> updateCandidates rinterface chunk_size candidates) :: IO.RInterface -> IO [Candidate]
    candidates' <- IO.withRInterface pid action
    return $ state{psCandidates = candidates'}

applyWriter :: Writer.Writer -> PeepState -> IO PeepState
applyWriter writer peepstate = do
    let pid = psPID peepstate
    let candidates = psCandidates peepstate
    let action = (\winterface -> applyWriterHelper winterface writer candidates) :: (IO.WInterface -> IO [Candidate])
    candidates' <- IO.withWInterface pid action
    return $ peepstate{psCandidates = candidates'}

scanMapS :: Size -> [Type] -> Filters.Filter -> Maps.MapInfo -> IO PeepState
scanMapS chunk_size types fltr map = do
    let pid = (Maps.miPID map)
    candidates <- scanMapHelper chunk_size types fltr map
    return PeepState{psPID = pid, psCandidates = candidates, psRegions = map}

scanMap :: [Type] -> Filters.Filter -> Maps.MapInfo -> IO PeepState
scanMap = scanMapS 10000